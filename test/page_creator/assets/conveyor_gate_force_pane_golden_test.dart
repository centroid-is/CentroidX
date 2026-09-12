import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue, NodeId;
import 'package:rxdart/rxdart.dart';
import 'package:tfc/page_creator/assets/conveyor_gate.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/golden_tolerance.dart';
import '../../helpers/golden_platform.dart';

/// Loads real fonts so the pane's labels render as letterforms and its icons
/// as glyphs instead of the test font's solid boxes — same patterns as
/// `third_party_golden_test` (text) and `panes_golden_test` (MaterialIcons).
Future<void> loadRealFont() async {
  Future<void> loadFont(String family, String path) async {
    final bytes = File(path).readAsBytesSync();
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(bytes.buffer))))
        .load();
  }

  await loadFont('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

  // The header and chip carry icons; pull MaterialIcons out of the Flutter
  // SDK cache, falling back to boxes rather than failing the suite.
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  for (final candidate in <String>[
    if (flutterRoot != null)
      '$flutterRoot/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf',
    '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/'
        'MaterialIcons-Regular.otf',
  ]) {
    if (File(candidate).existsSync()) {
      await loadFont('MaterialIcons', candidate);
      break;
    }
  }
}

/// Goldens of the gate force pane, one per control shape.
///
/// A diverter is held in a position, so it gets the tri-state Open / None /
/// Close selector — shown here with force-open feedback active, so the header
/// carries the orange `Forced open` chip and the Open segment wears the same
/// tint. A pusher strokes out and returns, so it gets a single press-and-hold
/// button, shown both at rest and held down.
void main() {
  // This golden is a full 800×600 app surface with real text, so the
  // cross-Flutter-version antialiasing drift the default 0.01% tolerance
  // absorbs on small painter goldens is not enough here (CI measured 0.03%
  // on the text-free version). A real regression — a missing segment or a
  // moved highlight — shifts well over 1% of the frame.
  useTolerantGoldenComparator(tolerance: 0.002);

  group('gate force pane golden',
      skip: goldenSkip, () {
    setUpAll(loadRealFont);
    tearDown(closeSidePane);

    Future<void> pumpGate(WidgetTester tester, ConveyorGateConfig config,
        _FakeStateMan fake) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [stateManProvider.overrideWith((_) async => fake)],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 100,
                height: 100,
                child: ConveyorGate(config: config),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.byType(ConveyorGate));
      await tester.pumpAndSettle();
    }

    testWidgets('diverter force pane with open force active', (tester) async {
      final fake = _FakeStateMan();
      fake.push('gate/state', true);
      fake.push('gate/fo_fb', true);
      fake.push('gate/fc_fb', false);

      await pumpGate(
        tester,
        ConveyorGateConfig(
          gateVariant: GateVariant.pneumatic,
          stateKey: 'gate/state',
          forceOpenKey: 'gate/force_open',
          forceCloseKey: 'gate/force_close',
          forceOpenFeedbackKey: 'gate/fo_fb',
          forceCloseFeedbackKey: 'gate/fc_fb',
        ),
        fake,
      );

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/conveyor_gate_force_pane.png'),
      );
    });

    testWidgets('pusher force pane at rest', (tester) async {
      final fake = _FakeStateMan();
      fake.push('gate/state', false);

      await pumpGate(
        tester,
        ConveyorGateConfig(
          gateVariant: GateVariant.pusher,
          stateKey: 'gate/state',
          forceOpenKey: 'gate/force_open',
        ),
        fake,
      );

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/conveyor_gate_pusher_force_pane.png'),
      );
    });

    testWidgets('pusher force pane held down', (tester) async {
      final fake = _FakeStateMan();
      fake.push('gate/state', true);

      await pumpGate(
        tester,
        ConveyorGateConfig(
          gateVariant: GateVariant.pusher,
          stateKey: 'gate/state',
          forceOpenKey: 'gate/force_open',
        ),
        fake,
      );

      // Held, not tapped: the whole point of this control is what it looks
      // like under the operator's finger.
      final press =
          await tester.startGesture(tester.getCenter(find.text('Press to push')));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/conveyor_gate_pusher_force_pane_held.png'),
      );

      await press.up();
      await tester.pumpAndSettle();
    });
  });
}

class _FakeStateMan implements StateMan {
  final Map<String, BehaviorSubject<DynamicValue>> _streams = {};

  void push(String key, bool value) {
    _streams
        .putIfAbsent(key, () => BehaviorSubject<DynamicValue>())
        .add(DynamicValue(value: value, typeId: NodeId.boolean));
  }

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    return _streams
        .putIfAbsent(key, () => BehaviorSubject<DynamicValue>())
        .stream;
  }

  @override
  Future<void> write(String key, DynamicValue value) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      '_FakeStateMan: ${invocation.memberName} not implemented in test scope',
    );
  }
}
