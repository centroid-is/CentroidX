import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc_dart/core/collector.dart' show CollectEntry;
import 'package:tfc/page_creator/assets/sensor.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:tfc/widgets/panes/side_pane.dart';

/// Builds an `ST_Sensor_HMI`-shaped [DynamicValue], the way the OPC UA client
/// hands one over: a struct whose members are the `p_stat_*` / `p_cfg_*`
/// names declared in `SVNCoreComponents/DigitalSignals/Sensor/ST_Sensor_HMI`.
///
/// `TIME` members cross the wire as a millisecond count, so they are seeded as
/// ints here — that is the shape [SensorFbState] has to decode.
DynamicValue fbStruct({
  bool output = false,
  bool rawNO = false,
  bool rawNC = false,
  bool fault = false,
  bool hasNC = false,
  int blockedForMs = 0,
  int clearForMs = 0,
  int onDelayMs = 0,
  int offDelayMs = 20,
}) {
  return DynamicValue.fromMap(LinkedHashMap<String, dynamic>.from({
    SensorFbFields.rawNO: rawNO,
    SensorFbFields.rawNC: rawNC,
    SensorFbFields.fault: fault,
    SensorFbFields.hasNC: hasNC,
    SensorFbFields.output: output,
    SensorFbFields.blockedFor: blockedForMs,
    SensorFbFields.clearFor: clearForMs,
    SensorFbFields.onDelay: onDelayMs,
    SensorFbFields.offDelay: offDelayMs,
  }));
}

void main() {
  group('SensorFbState.tryParse', () {
    test('decodes every member of an ST_Sensor_HMI struct', () {
      final state = SensorFbState.tryParse(fbStruct(
        output: true,
        rawNO: true,
        rawNC: false,
        fault: false,
        hasNC: true,
        blockedForMs: 4200,
        clearForMs: 0,
        onDelayMs: 50,
        offDelayMs: 20,
      ));

      expect(state, isNotNull);
      expect(state!.output, isTrue);
      expect(state.rawNO, isTrue);
      expect(state.rawNC, isFalse);
      expect(state.fault, isFalse);
      expect(state.hasNC, isTrue);
      expect(state.blockedFor, const Duration(milliseconds: 4200));
      expect(state.clearFor, Duration.zero);
      expect(state.onDelay, const Duration(milliseconds: 50));
      expect(state.offDelay, const Duration(milliseconds: 20));
    });

    test('returns null for a plain BOOL node (legacy binding)', () {
      expect(SensorFbState.tryParse(DynamicValue(value: true)), isNull);
      expect(SensorFbState.tryParse(DynamicValue(value: false)), isNull);
    });

    test('returns null for a struct that is not an FB_Sensor HMI', () {
      // A conveyor's HMI struct, say — an object, but with no p_stat_xOutput.
      final other = DynamicValue.fromMap(LinkedHashMap<String, dynamic>.from({
        'p_stat_Frequency': 12.5,
        'p_cfg_AutoFreq': 30.0,
      }));
      expect(SensorFbState.tryParse(other), isNull);
    });

    test('returns null for a null value', () {
      expect(SensorFbState.tryParse(DynamicValue()), isNull);
    });

    test('tolerates a struct missing the optional members', () {
      // An older library revision that publishes the output but not the NC
      // pair must degrade to defaults, not throw — `DynamicValue.operator[]`
      // throws on a missing key, which is what the guarded reads exist for.
      final partial = DynamicValue.fromMap(LinkedHashMap<String, dynamic>.from({
        SensorFbFields.output: true,
      }));
      final state = SensorFbState.tryParse(partial);
      expect(state, isNotNull);
      expect(state!.output, isTrue);
      expect(state.rawNC, isFalse);
      expect(state.hasNC, isFalse);
      expect(state.fault, isFalse);
      expect(state.onDelay, Duration.zero);
      expect(state.offDelay, Duration.zero);
    });
  });

  group('formatSensorElapsed', () {
    test('sub-minute renders as seconds with one decimal', () {
      expect(formatSensorElapsed(const Duration(milliseconds: 4200)),
          ('4.2', 's'));
      expect(formatSensorElapsed(Duration.zero), ('0.0', 's'));
    });

    test('sub-hour renders as m:s', () {
      expect(formatSensorElapsed(const Duration(minutes: 5, seconds: 3)),
          ('5:03', 'm:s'));
    });

    test('an hour or more renders as h:m', () {
      expect(formatSensorElapsed(const Duration(hours: 2, minutes: 7)),
          ('2:07', 'h:m'));
      // q_tBlockedFor caps at one day — the top of the range must still read.
      expect(formatSensorElapsed(const Duration(days: 1)), ('24:00', 'h:m'));
    });
  });

  group('sensorTrendAvailable', () {
    test('a plain BOOL binding charts as soon as the key is gathered', () {
      expect(
          sensorTrendAvailable(
              isStruct: false, collect: CollectEntry(key: '/k')),
          isTrue);
      expect(sensorTrendAvailable(isStruct: false, collect: null), isFalse);
    });

    test('a struct binding needs the output bit in sample_members', () {
      expect(
          sensorTrendAvailable(
            isStruct: true,
            collect: CollectEntry(
                key: '/k', sampleMembers: [SensorFbFields.output]),
          ),
          isTrue);
      expect(
          sensorTrendAvailable(
            isStruct: true,
            collect:
                CollectEntry(key: '/k', sampleMembers: ['p_stat_xRaw']),
          ),
          isFalse,
          reason: 'Gathering other members does not make the output '
              'chartable.');
      expect(
          sensorTrendAvailable(isStruct: true, collect: CollectEntry(key: '/k')),
          isFalse,
          reason: 'A whole-struct series has nothing the graph can draw.');
    });
  });

  group('SensorFbPane', () {
    late List<(String, Object?)> writes;

    Widget wrap(SensorFbState state,
        {SensorConfig? config, Widget? trendTile}) {
      writes = [];
      return MaterialApp(
        home: Scaffold(
          body: SensorFbPane(
            config: config ??
                SensorConfig(detectionKey: 'sensors.CVS01_CN01_PX01.HMI'),
            state: state,
            onWrite: (field, value) => writes.add((field, value)),
            trendTile: trendTile,
          ),
        ),
      );
    }

    /// A provider-free stand-in for the real trend tile — the pane only
    /// slots it in, so its contents are not under test here.
    Widget cannedTrendTile() => PaneGraphTile(
          height: 64,
          preview: const SizedBox.expand(),
          expandedBuilder: (_) => const SizedBox(),
        );

    testWidgets('shows the debounce as live read-only values', (tester) async {
      await tester.pumpWidget(wrap(SensorFbState.tryParse(
        fbStruct(onDelayMs: 50, offDelayMs: 20),
      )!));

      expect(find.text('On delay'), findsOneWidget);
      expect(find.text('Off delay'), findsOneWidget);
      expect(find.text('50 ms'), findsOneWidget);
      expect(find.text('20 ms'), findsOneWidget);
    });

    testWidgets('the setpoint fields sit folded behind Adjust',
        (tester) async {
      await tester.pumpWidget(wrap(SensorFbState.tryParse(
        fbStruct(onDelayMs: 50, offDelayMs: 20),
      )!));

      // Retuning is a rare, deliberate act: no editable field may be
      // reachable on the pane's first paint.
      expect(find.byType(TextFormField), findsNothing);

      await tester.tap(find.text('Adjust'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextFormField, '50'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '20'), findsOneWidget);
    });

    /// Opens the collapsed Adjust fold so the setpoint fields exist.
    Future<void> expandAdjust(WidgetTester tester) async {
      await tester.tap(find.text('Adjust'));
      await tester.pumpAndSettle();
    }

    testWidgets('submitting the on-delay field writes p_cfg_tOnDelay',
        (tester) async {
      await tester.pumpWidget(wrap(SensorFbState.tryParse(
        fbStruct(onDelayMs: 50, offDelayMs: 20),
      )!));
      await expandAdjust(tester);

      final onDelay = find.byKey(const Key('sensor_on_delay_field'));
      await tester.enterText(onDelay, '120');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(writes, [(SensorFbFields.onDelay, 120)]);
    });

    testWidgets('submitting the off-delay field writes p_cfg_tOffDelay',
        (tester) async {
      await tester.pumpWidget(wrap(SensorFbState.tryParse(
        fbStruct(onDelayMs: 50, offDelayMs: 20),
      )!));
      await expandAdjust(tester);

      final offDelay = find.byKey(const Key('sensor_off_delay_field'));
      await tester.enterText(offDelay, '35');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(writes, [(SensorFbFields.offDelay, 35)]);
    });

    testWidgets('a negative or unparseable delay is not written',
        (tester) async {
      await tester.pumpWidget(wrap(SensorFbState.tryParse(
        fbStruct(onDelayMs: 50),
      )!));
      await expandAdjust(tester);

      final onDelay = find.byKey(const Key('sensor_on_delay_field'));
      await tester.enterText(onDelay, '-50');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.enterText(onDelay, 'abc');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(writes, isEmpty,
          reason: 'TIME is unsigned — a bad entry must be rejected, never '
              'silently clamped into a value the operator did not type.');
    });

    testWidgets('the pane writes nothing on its own', (tester) async {
      await tester.pumpWidget(wrap(SensorFbState.tryParse(fbStruct())!));
      await tester.pumpAndSettle();
      expect(writes, isEmpty,
          reason: 'Opening a sensor pane must not touch the PLC.');
    });

    testWidgets('status is Blocked when the output is set', (tester) async {
      await tester
          .pumpWidget(wrap(SensorFbState.tryParse(fbStruct(output: true))!));
      expect(find.text('Blocked'), findsOneWidget);
    });

    testWidgets('status is Clear when the output is not set', (tester) async {
      await tester
          .pumpWidget(wrap(SensorFbState.tryParse(fbStruct(output: false))!));
      expect(find.text('Clear'), findsOneWidget);
    });

    testWidgets('fault outranks the output in the status chip', (tester) async {
      await tester.pumpWidget(wrap(SensorFbState.tryParse(
        fbStruct(output: true, fault: true, hasNC: true),
      )!));

      expect(find.text('Signal fault'), findsOneWidget);
      expect(find.text('Blocked'), findsNothing);
      expect(find.text('NO and NC both inactive'), findsOneWidget);
      // The Output row must not contradict the glyph, which greys out on
      // fault: with neither contact reporting, the state is not knowable.
      expect(find.text('unknown'), findsOneWidget);
      expect(find.text('clear'), findsNothing);
    });

    testWidgets('the raw NO/NC rows are gone — the Output row is the reading',
        (tester) async {
      await tester.pumpWidget(wrap(SensorFbState.tryParse(
        fbStruct(rawNO: true, rawNC: true, hasNC: true),
      )!));
      expect(find.text('Raw NO'), findsNothing);
      expect(find.text('Raw NC'), findsNothing,
          reason: 'The undebounced bits are diagnostics, not operator '
              'readings; the Fault row carries the message when the '
              'contacts disagree.');
    });

    testWidgets('no Binding section, no key strings — values only',
        (tester) async {
      await tester.pumpWidget(wrap(SensorFbState.tryParse(fbStruct())!));

      expect(find.text('Binding'), findsNothing);
      expect(find.text('BINDING'), findsNothing);
      expect(find.text('Detection key'), findsNothing);
      expect(find.textContaining('sensors.CVS01_CN01_PX01'), findsNothing,
          reason: 'Key strings are wiring — an operator surface must not '
              'show them, not even as the pane title.');
    });

    testWidgets('elapsed times are surfaced as metric tiles', (tester) async {
      await tester.pumpWidget(wrap(SensorFbState.tryParse(
        fbStruct(output: true, blockedForMs: 4200, clearForMs: 0),
      )!));

      expect(find.byType(PaneMetricTile), findsNWidgets(2));
      expect(find.text('Blocked for'), findsOneWidget);
      expect(find.text('Clear for'), findsOneWidget);
      expect(find.text('4.2'), findsOneWidget);
    });

    testWidgets('the pane is not the config editor (SENS-01)', (tester) async {
      await tester.pumpWidget(wrap(SensorFbState.tryParse(fbStruct())!));

      expect(find.byType(SidePane), findsOneWidget);
      // The editor's markers must not leak into an operator surface.
      expect(find.byType(SegmentedButton<SensorKind>), findsNothing);
      expect(find.text('Detection State Key'), findsNothing);
      expect(find.byType(SwitchListTile), findsNothing);
    });

    testWidgets('an inline trend tile appears when the key is gathered',
        (tester) async {
      await tester.pumpWidget(wrap(
        SensorFbState.tryParse(fbStruct())!,
        trendTile: cannedTrendTile(),
      ));
      expect(find.text('TREND'), findsOneWidget,
          reason: 'The trend rides its own PaneSection between Signal and '
              'Debounce, like the conveyor pane.');
      expect(find.byType(PaneGraphTile), findsOneWidget);
    });

    testWidgets('no trend section without data gathering', (tester) async {
      await tester.pumpWidget(wrap(SensorFbState.tryParse(fbStruct())!));
      expect(find.text('TREND'), findsNothing,
          reason: 'A chart with nothing behind it is a broken promise — '
              'the section must be absent, not empty.');
      expect(find.byType(PaneGraphTile), findsNothing);
    });

    testWidgets('the tag names the pane', (tester) async {
      await tester.pumpWidget(wrap(
        SensorFbState.tryParse(fbStruct())!,
        config: SensorConfig(
          detectionKey: 'sensors.CVS01_CN01_PX01.HMI',
          tag: 'PE-101A',
        ),
      ));
      expect(find.text('PE-101A'), findsOneWidget);
    });

    testWidgets('an untagged sensor falls back to a generic title',
        (tester) async {
      await tester.pumpWidget(wrap(SensorFbState.tryParse(fbStruct())!));
      expect(find.text('Sensor'), findsOneWidget);
    });
  });
}
