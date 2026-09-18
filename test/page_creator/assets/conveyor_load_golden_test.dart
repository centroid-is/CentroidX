import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/theme.dart';
import '../../helpers/golden_platform.dart';

const _key = Key('conveyor_load_golden');

/// Real glyphs instead of Ahem boxes, so the row labels read. Registered as
/// 'dejavu-sans' because that is the family the app theme asks for — see
/// `roller_conveyor_golden_test.dart`.
Future<void> loadRealFont() async {
  final data = File('lib/fonts/dejavu-sans/DejaVuSans.ttf')
      .readAsBytesSync()
      .buffer
      .asByteData();
  final loader = FontLoader('dejavu-sans')..addFont(Future.value(data));
  await loader.load();
}

Map<String, Batch> _batch(double start, double end) =>
    {'0': Batch(start: start, end: end)};

/// Every way a load is drawn, box against pallet, so the two can be compared
/// on one sheet: mid-belt, sliding on and sliding off, on a roller bed, and
/// around a bend — plus the same pallet at two sizes, because every dimension
/// in it is a fraction of the load and must therefore survive a rescale.
Widget buildLoadScenario(ThemeData theme) {
  const beltSize = Size(300, 40);
  const bigBeltSize = Size(600, 80);
  const turnSize = Size(220, 150);

  Widget belt(Size size, ConveyorPainter painter) => SizedBox.fromSize(
        size: size,
        child: CustomPaint(size: size, painter: painter),
      );

  return MaterialApp(
    theme: theme,
    home: Builder(builder: (context) {
      final states = HmiStateColors.of(context);
      Widget row(String label, Widget child) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.bodySmall),
              child,
              const SizedBox(height: 10),
            ],
          );

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
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      row(
                        'box (unchanged)',
                        belt(
                          beltSize,
                          ConveyorPainter(
                            color: states.green,
                            batches: _batch(0.3, 0.62),
                            angle: 0,
                          ),
                        ),
                      ),
                      row(
                        'euro pallet',
                        belt(
                          beltSize,
                          ConveyorPainter(
                            color: states.green,
                            batches: _batch(0.3, 0.62),
                            angle: 0,
                            load: ConveyorLoad.euroPallet,
                          ),
                        ),
                      ),
                      row(
                        'euro pallet, across the belt',
                        belt(
                          beltSize,
                          ConveyorPainter(
                            color: states.green,
                            batches: _batch(0.3, 0.62),
                            angle: 0,
                            load: ConveyorLoad.euroPallet,
                            palletOrientation: PalletOrientation.acrossBelt,
                          ),
                        ),
                      ),
                      row(
                        'pallet sliding on and off',
                        belt(
                          beltSize,
                          ConveyorPainter(
                            color: states.green,
                            batches: {
                              'in': Batch(start: -0.22, end: 0.1),
                              'out': Batch(start: 0.88, end: 1.2),
                            },
                            angle: 0,
                            load: ConveyorLoad.euroPallet,
                          ),
                        ),
                      ),
                      row(
                        'pallet on rollers, belt stopped',
                        belt(
                          beltSize,
                          ConveyorPainter(
                            color: states.grey,
                            batches: _batch(0.34, 0.66),
                            angle: 0,
                            style: ConveyorStyle.roller,
                            load: ConveyorLoad.euroPallet,
                          ),
                        ),
                      ),
                      row(
                        'same pallet at twice the size',
                        belt(
                          bigBeltSize,
                          ConveyorPainter(
                            color: states.green,
                            batches: _batch(0.3, 0.62),
                            angle: 0,
                            load: ConveyorLoad.euroPallet,
                          ),
                        ),
                      ),
                      row(
                        'across the belt at twice the size',
                        belt(
                          bigBeltSize,
                          ConveyorPainter(
                            color: states.green,
                            batches: _batch(0.3, 0.62),
                            angle: 0,
                            load: ConveyorLoad.euroPallet,
                            palletOrientation: PalletOrientation.acrossBelt,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 20),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      row(
                        'turned, box',
                        belt(
                          turnSize,
                          ConveyorPainter(
                            color: states.green,
                            batches: _batch(0.2, 0.4),
                            angle: 0,
                            geometry: ConveyorPathGeometry.build(
                              [
                                ConveyorTurnEntry(
                                    position: 0.5, angle: 90, radius: 1.5)
                              ],
                              turnSize,
                              thicknessFactor: 0.3,
                            ),
                          ),
                        ),
                      ),
                      row(
                        'turned, pallet before the bend',
                        belt(
                          turnSize,
                          ConveyorPainter(
                            color: states.green,
                            batches: _batch(0.2, 0.4),
                            angle: 0,
                            load: ConveyorLoad.euroPallet,
                            geometry: ConveyorPathGeometry.build(
                              [
                                ConveyorTurnEntry(
                                    position: 0.5, angle: 90, radius: 1.5)
                              ],
                              turnSize,
                              thicknessFactor: 0.3,
                            ),
                          ),
                        ),
                      ),
                      row(
                        'turned, pallet across the belt',
                        belt(
                          turnSize,
                          ConveyorPainter(
                            color: states.green,
                            batches: _batch(0.2, 0.4),
                            angle: 0,
                            load: ConveyorLoad.euroPallet,
                            palletOrientation: PalletOrientation.acrossBelt,
                            geometry: ConveyorPathGeometry.build(
                              [
                                ConveyorTurnEntry(
                                    position: 0.5, angle: 90, radius: 1.5)
                              ],
                              turnSize,
                              thicknessFactor: 0.3,
                            ),
                          ),
                        ),
                      ),
                      row(
                        'turned, pallet in the bend',
                        belt(
                          turnSize,
                          ConveyorPainter(
                            color: states.yellow,
                            batches: _batch(0.45, 0.65),
                            angle: 0,
                            load: ConveyorLoad.euroPallet,
                            geometry: ConveyorPathGeometry.build(
                              [
                                ConveyorTurnEntry(
                                    position: 0.5, angle: 90, radius: 1.5)
                              ],
                              turnSize,
                              thicknessFactor: 0.3,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }),
  );
}

void main() {
  group('Conveyor load golden tests', skip: goldenSkip, () {
    setUpAll(loadRealFont);
    final cases = <String, ThemeData>{
      'solarized_light': solarized().$1,
      'solarized_dark': solarized().$2,
    };
    for (final entry in cases.entries) {
      testWidgets('box and euro pallet loads under ${entry.key}',
          (tester) async {
        tester.view.physicalSize = const Size(1200, 1100);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(buildLoadScenario(entry.value));
        await expectLater(
          find.byKey(_key),
          matchesGoldenFile('goldens/conveyor_load_${entry.key}.png'),
        );
      });
    }
  });
}
