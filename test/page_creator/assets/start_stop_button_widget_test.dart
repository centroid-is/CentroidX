import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue, NodeId;
import 'package:rxdart/rxdart.dart';
import 'package:tfc/page_creator/assets/start_stop_button.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_dart/core/state_man.dart';

/// Widget tests for the manual peer-mode segment on the start/stop pill.
///
/// Contract under test:
///   - manualStateKey == null AND manualCommandKey == null   → manual
///                                                              segment is
///                                                              ABSENT
///                                                              (pill stays
///                                                              3 segments)
///   - either manual_* key set                               → manual
///                                                              segment is
///                                                              rendered as
///                                                              a 4th peer
///                                                              segment
///   - manualStateKey stream emits true                      → manual
///                                                              segment
///                                                              shows the
///                                                              active-state
///                                                              accent
///                                                              (orange)
///   - manualStateKey stream emits false                     → manual
///                                                              segment
///                                                              shows the
///                                                              inactive-state
///                                                              color (same
///                                                              tint
///                                                              run/stop use
///                                                              when not
///                                                              active)
///   - tap on manual segment                                 → write pulse
///                                                              of `true`
///                                                              fires on
///                                                              manualCommandKey
///
/// Manual is a PEER MODE, not a gate. There is NO lockout semantics:
/// every other segment must remain individually tappable regardless of
/// the manual state.
void main() {
  Widget wrap({
    required Widget child,
    List<Override> overrides = const [],
  }) {
    return ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  /// All segment GestureDetectors inside the pill (one per segment).
  Finder segmentGestureDetectors() => find.descendant(
        of: find.byType(StartStopPillButton),
        matching: find.byType(GestureDetector),
      );

  /// The Icon widget for a given FA icon (Start=play, Stop=stop,
  /// Clean=droplet, Manual=hand).
  Finder iconByData(IconData data) => find.byWidgetPredicate(
        (w) => w is Icon && w.icon == data,
      );

  group('manual segment visibility', () {
    testWidgets('manualStateKey + manualCommandKey null → manual hidden',
        (tester) async {
      final config = StartStopPillButtonConfig.preview();
      await tester.pumpWidget(wrap(
        child: SizedBox(
          width: 240,
          height: 80,
          child: StartStopPillButton(config),
        ),
      ));
      await tester.pump();
      expect(iconByData(FontAwesomeIcons.screwdriverWrench.data), findsNothing,
          reason: 'no manual_* keys → manual segment must not render');
      // Preview has no cleanKey either → 2 segments (run + stop).
      expect(segmentGestureDetectors(), findsNWidgets(2));
    });

    testWidgets('only manualStateKey set → manual segment renders',
        (tester) async {
      final fake = _FakeStateMan();
      fake.push('fb/manual', false);
      final config = StartStopPillButtonConfig(
        runKey: 'cmd/run',
        stopKey: 'cmd/stop',
        runningKey: 'fb/running',
        stoppedKey: 'fb/stopped',
      )..manualStateKey = 'fb/manual';

      await tester.pumpWidget(wrap(
        overrides: [stateManProvider.overrideWith((_) async => fake)],
        child: SizedBox(
          width: 320,
          height: 80,
          child: StartStopPillButton(config),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(iconByData(FontAwesomeIcons.screwdriverWrench.data), findsOneWidget,
          reason: 'manualStateKey present → manual icon visible');
      // 3 segments: run + stop + manual.
      expect(segmentGestureDetectors(), findsNWidgets(3));
    });

    testWidgets('only manualCommandKey set → manual segment renders',
        (tester) async {
      final config = StartStopPillButtonConfig(
        runKey: 'cmd/run',
        stopKey: 'cmd/stop',
        runningKey: 'fb/running',
        stoppedKey: 'fb/stopped',
      )..manualCommandKey = 'cmd/manual';
      final fake = _FakeStateMan();

      await tester.pumpWidget(wrap(
        overrides: [stateManProvider.overrideWith((_) async => fake)],
        child: SizedBox(
          width: 320,
          height: 80,
          child: StartStopPillButton(config),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(iconByData(FontAwesomeIcons.screwdriverWrench.data), findsOneWidget,
          reason: 'manualCommandKey present → manual icon visible');
    });
  });

  group('manual segment state indicator', () {
    testWidgets('manualStateKey stream=true → manual icon paints in accent',
        (tester) async {
      final fake = _FakeStateMan();
      fake.push('fb/manual', true);
      final config = StartStopPillButtonConfig(
        runKey: 'cmd/run',
        stopKey: 'cmd/stop',
        runningKey: 'fb/running',
        stoppedKey: 'fb/stopped',
      )
        ..manualStateKey = 'fb/manual'
        ..manualCommandKey = 'cmd/manual';

      await tester.pumpWidget(wrap(
        overrides: [stateManProvider.overrideWith((_) async => fake)],
        child: SizedBox(
          width: 320,
          height: 80,
          child: StartStopPillButton(config),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final manualIcon =
          tester.widget<Icon>(iconByData(FontAwesomeIcons.screwdriverWrench.data));
      // Manual's accent color is orange (industrial convention for
      // operator override).
      expect(manualIcon.color, Colors.orange,
          reason: 'stream=true → manual icon paints in orange accent');
    });

    testWidgets('manualStateKey stream=false → manual icon NOT in accent',
        (tester) async {
      final fake = _FakeStateMan();
      fake.push('fb/manual', false);
      // Set stopped=true so SOME segment owns the active accent — the
      // assertion is purely "manual is not the active one".
      fake.push('fb/stopped', true);
      final config = StartStopPillButtonConfig(
        runKey: 'cmd/run',
        stopKey: 'cmd/stop',
        runningKey: 'fb/running',
        stoppedKey: 'fb/stopped',
      )
        ..manualStateKey = 'fb/manual'
        ..manualCommandKey = 'cmd/manual';

      await tester.pumpWidget(wrap(
        overrides: [stateManProvider.overrideWith((_) async => fake)],
        child: SizedBox(
          width: 320,
          height: 80,
          child: StartStopPillButton(config),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final manualIcon =
          tester.widget<Icon>(iconByData(FontAwesomeIcons.screwdriverWrench.data));
      expect(manualIcon.color, isNot(Colors.orange),
          reason: 'stream=false → manual icon does NOT paint in accent');
    });
  });

  group('manual segment command pulse', () {
    testWidgets('tap on manual segment writes true to manualCommandKey',
        (tester) async {
      final fake = _FakeStateMan();
      fake.push('fb/manual', false);
      final config = StartStopPillButtonConfig(
        runKey: 'cmd/run',
        stopKey: 'cmd/stop',
        runningKey: 'fb/running',
        stoppedKey: 'fb/stopped',
      )
        ..manualStateKey = 'fb/manual'
        ..manualCommandKey = 'cmd/manual';

      await tester.pumpWidget(wrap(
        overrides: [stateManProvider.overrideWith((_) async => fake)],
        child: SizedBox(
          width: 320,
          height: 80,
          child: StartStopPillButton(config),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Tap the manual icon. Use tap-down to mirror how the other modes
      // pulse on press.
      final gesture =
          await tester.startGesture(tester.getCenter(iconByData(FontAwesomeIcons.screwdriverWrench.data)));
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 20));

      // We expect at least one true-pulse and one false-release on
      // cmd/manual (mirrors the existing run/stop pulse semantics).
      final writesToManual = fake.writes
          .where((w) => w.key == 'cmd/manual')
          .toList();
      expect(writesToManual, isNotEmpty,
          reason: 'manual tap must hit manualCommandKey');
      expect(writesToManual.first.value, true,
          reason: 'first write on tap-down must be true (pulse high)');
    });
  });

  group('manual peer mode does NOT introduce lockout semantics', () {
    testWidgets(
        'manualStateKey stream=false does NOT disable run/stop segments',
        (tester) async {
      final fake = _FakeStateMan();
      fake.push('fb/manual', false);
      final config = StartStopPillButtonConfig(
        runKey: 'cmd/run',
        stopKey: 'cmd/stop',
        runningKey: 'fb/running',
        stoppedKey: 'fb/stopped',
      )
        ..manualStateKey = 'fb/manual'
        ..manualCommandKey = 'cmd/manual';

      await tester.pumpWidget(wrap(
        overrides: [stateManProvider.overrideWith((_) async => fake)],
        child: SizedBox(
          width: 320,
          height: 80,
          child: StartStopPillButton(config),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Every segment's GestureDetector MUST still have its tap
      // callbacks wired. Manual is a peer mode, not a gate.
      final detectors = tester
          .widgetList<GestureDetector>(segmentGestureDetectors())
          .toList();
      expect(detectors, isNotEmpty);
      for (final d in detectors) {
        expect(d.onTapDown, isNotNull,
            reason: 'peer mode must NOT clear onTapDown on other segments');
        expect(d.onTapUp, isNotNull,
            reason: 'peer mode must NOT clear onTapUp on other segments');
        expect(d.onTapCancel, isNotNull,
            reason:
                'peer mode must NOT clear onTapCancel on other segments');
      }
    });
  });
}

/// Minimal stand-in for [StateMan] that lets tests push synchronous values
/// for a given key AND records all writes.
class _FakeStateMan implements StateMan {
  final Map<String, BehaviorSubject<DynamicValue>> _streams = {};
  final List<_Write> writes = [];

  void push(String key, bool value) {
    final s = _streams.putIfAbsent(
      key,
      () => BehaviorSubject<DynamicValue>(),
    );
    s.add(DynamicValue(value: value, typeId: NodeId.boolean));
  }

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    final s = _streams.putIfAbsent(
      key,
      () => BehaviorSubject<DynamicValue>(),
    );
    return s.stream;
  }

  @override
  Future<void> write(String key, DynamicValue value) async {
    writes.add(_Write(key, value.asBool));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      '_FakeStateMan: ${invocation.memberName} not implemented in test scope',
    );
  }
}

class _Write {
  final String key;
  final bool value;
  _Write(this.key, this.value);
}
