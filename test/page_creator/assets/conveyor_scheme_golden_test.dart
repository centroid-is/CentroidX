
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/led.dart';
import 'package:tfc/theme.dart';
import '../../helpers/golden_platform.dart';

const _key = Key('conveyor_scheme_test');

/// The legend asset plus one straight belt per equipment state, rendered
/// under a real app theme so every color flows through [HmiStateColors].
Widget buildSchemeScenario(ThemeData theme) {
  final palette = ConveyorColorPaletteConfig()
    ..size = const RelativeSize(width: 0.25, height: 0.6);
  const beltSize = Size(240, 24);
  return ProviderScope(
      child: MaterialApp(
    theme: theme,
    home: Builder(builder: (context) {
      final states = HmiStateColors.of(context);
      final belts = {
        'auto': states.green,
        'manual': states.yellow,
        'clean': states.blue,
        'stopped': states.grey,
        'fault': states.red,
        'unknown': states.violet,
      };
      return Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: _key,
            child: Container(
              color: theme.colorScheme.surface,
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ConveyorColorPalette(config: palette),
                  const SizedBox(width: 24),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Default LED (role-backed AssetColor): on = running.
                      Text('led (default on)',
                          style: theme.textTheme.bodySmall),
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: LedRaw(LEDConfig(key: LEDConfig.previewStr)),
                      ),
                      const SizedBox(height: 8),
                      for (final entry in belts.entries) ...[
                        Text(entry.key, style: theme.textTheme.bodySmall),
                        SizedBox.fromSize(
                          size: beltSize,
                          child: CustomPaint(
                            size: beltSize,
                            painter: ConveyorPainter(
                              color: entry.value,
                              batches: const {},
                              angle: 0,
                              geometry: ConveyorPathGeometry.build(
                                  const [], beltSize),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }),
  ));
}

void main() {
  group('Conveyor color scheme golden tests',
      skip: goldenSkip, () {
    final cases = <String, ThemeData>{
      'solarized_light': solarized().$1,
      'solarized_dark': solarized().$2,
      'muted_light': muted().$1,
      'muted_dark': muted().$2,
    };
    for (final entry in cases.entries) {
      testWidgets('conveyor states under ${entry.key}', (tester) async {
        await tester.pumpWidget(buildSchemeScenario(entry.value));
        await expectLater(
          find.byKey(_key),
          matchesGoldenFile('goldens/conveyor_states_${entry.key}.png'),
        );
      });
    }
  });
}
