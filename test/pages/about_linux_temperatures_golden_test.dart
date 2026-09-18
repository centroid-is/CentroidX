/// Goldens for the Temperatures section of the About Linux page.
///
/// A typical Intel panel PC's sensors, once all cool and once with the NVMe
/// past its max and the CPU at its crit, so the yellow and red states are on
/// record next to the plain one.
///
/// To update: scripts/goldens.sh --update test/pages/about_linux_temperatures_golden_test.dart
@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/hardware_temperatures.dart';
import 'package:tfc/theme.dart' show solarized;
import 'package:tfc/widgets/hardware_temperatures_section.dart';

import '../helpers/golden_fonts.dart';
import '../helpers/golden_platform.dart';

const Size _viewport = Size(720, 220);

const _cool = [
  TemperatureReading(label: 'Board (ACPI)', celsius: 27.8, critical: 105),
  TemperatureReading(
      label: 'CPU package', celsius: 51, high: 100, critical: 100),
  TemperatureReading(
      label: 'CPU cores',
      celsius: 53,
      minCelsius: 44,
      count: 11,
      high: 100,
      critical: 100),
  TemperatureReading(
      label: 'NVMe', celsius: 38.85, high: 84.85, critical: 89.85),
];

const _hot = [
  TemperatureReading(label: 'Board (ACPI)', celsius: 41, critical: 105),
  TemperatureReading(
      label: 'CPU package', celsius: 100, high: 100, critical: 100),
  TemperatureReading(
      label: 'CPU cores',
      celsius: 100,
      minCelsius: 93,
      count: 11,
      high: 100,
      critical: 100),
  TemperatureReading(
      label: 'NVMe', celsius: 86, high: 84.85, critical: 89.85),
];

Widget _card(List<TemperatureReading> readings, {bool dark = false}) {
  final (light, darkTheme) = solarized();
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: dark ? darkTheme : light,
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [HardwareTemperaturesCard(readings: readings)],
        ),
      ),
    ),
  );
}

Future<void> _pump(WidgetTester tester, Widget widget) async {
  await tester.binding.setSurfaceSize(_viewport);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();
}

Future<void> _expectGolden(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name'));

void main() {
  setUpAll(loadGoldenFonts);

  group('about linux temperatures', skip: goldenSkip, () {
    testWidgets('cool, light', (tester) async {
      await _pump(tester, _card(_cool));
      await _expectGolden(tester, 'about_linux_temperatures_light.png');
    });

    testWidgets('cool, dark', (tester) async {
      await _pump(tester, _card(_cool, dark: true));
      await _expectGolden(tester, 'about_linux_temperatures_dark.png');
    });

    testWidgets('high and critical, light', (tester) async {
      await _pump(tester, _card(_hot));
      await _expectGolden(tester, 'about_linux_temperatures_hot.png');
    });
  });

  testWidgets('a host with no sensors draws nothing', (tester) async {
    await _pump(
      tester,
      MaterialApp(
        home: Scaffold(
          body: HardwareTemperaturesSection(
            read: () async => const [],
            pollInterval: const Duration(hours: 1),
          ),
        ),
      ),
    );
    expect(find.text('Temperatures'), findsNothing);
    expect(find.byType(Divider), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the section shows what the reader returns', (tester) async {
    await _pump(
      tester,
      MaterialApp(
        home: Scaffold(
          body: HardwareTemperaturesSection(
            read: () async => _cool,
            pollInterval: const Duration(hours: 1),
          ),
        ),
      ),
    );
    expect(find.text('Temperatures'), findsOneWidget);
    expect(find.text('CPU package'), findsOneWidget);
    expect(find.text('44–53 °C'), findsOneWidget);
    // Unmount so the periodic timer is cancelled before the test ends.
    await tester.pumpWidget(const SizedBox());
  });
}
