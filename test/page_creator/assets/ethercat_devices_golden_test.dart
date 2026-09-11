import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/ethercat_devices.dart';
import 'package:tfc/page_creator/assets/ethercat_subdevice.dart';
import 'package:tfc/page_creator/assets/ethercat_subdevice_pane.dart';
import 'package:tfc/theme.dart';

import '../../helpers/golden_tolerance.dart';

const _key = Key('ethercat_devices');

/// A table is nothing but words and figures; under Ahem every cell is a
/// solid block and the golden proves the grid while saying nothing about it.
Future<void> loadRealFont() async {
  final data = File('lib/fonts/roboto-mono/RobotoMono-Regular.ttf')
      .readAsBytesSync()
      .buffer
      .asByteData();
  for (final family in ['Roboto', 'roboto-mono']) {
    await (FontLoader(family)..addFont(Future.value(data))).load();
  }
}

Widget frame(Widget child, {double width = 900, double height = 420}) {
  final (light, _) = solarized();
  return MaterialApp(
    theme: light,
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: Center(
        child: RepaintBoundary(
          key: _key,
          child: SizedBox(width: width, height: height, child: child),
        ),
      ),
    ),
  );
}

void main() {
  useTolerantGoldenComparator();

  group('EtherCAT devices',
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    testWidgets('two masters, one of everything the table shows',
        (tester) async {
      await loadRealFont();
      await tester.pumpWidget(frame(EcDeviceTableView(buses: ecSampleBuses())));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_devices_table.png'));
    });

    testWidgets('filtered to the rows that need somebody', (tester) async {
      await loadRealFont();
      await tester.pumpWidget(frame(EcDeviceTableView(
        buses: ecSampleBuses(),
        initialProblemsOnly: true,
      )));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_devices_problems.png'));
    });

    testWidgets('narrow: model and clean-for give way first', (tester) async {
      await loadRealFont();
      await tester.pumpWidget(
          frame(EcDeviceTableView(buses: ecSampleBuses()), width: 560));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_devices_narrow.png'));
    });

    for (final (name, bus, pos) in [
      ('warning', 0, 5), // CRC errors on port A in the last hour
      ('gone', 0, 7), // not answering on the bus
      ('branch', 1, 2), // a coupler with a drop off port C
    ]) {
      testWidgets('subdevice pane: $name', (tester) async {
        await loadRealFont();
        final b = ecSampleBuses()[bus];
        await tester.pumpWidget(frame(
          SingleChildScrollView(
            child: EcSubDevicePaneBody(
              bus: b,
              subdevice: b.at(pos)!,
              onReset: (_) async {},
            ),
          ),
          width: 380,
          height: 620,
        ));
        await tester.pumpAndSettle();
        await expectLater(find.byKey(_key),
            matchesGoldenFile('goldens/ethercat_subdevice_pane_$name.png'));
      });
    }
  });

  test('the sample covers what the goldens claim', () {
    final buses = ecSampleBuses();
    expect(buses[0].at(5)!.health, EcHealth.warning);
    expect(buses[0].at(7)!.health, EcHealth.fault);
    expect(buses[1].neighbour(buses[1].at(2)!, EcPort.c)!.subdevice!.label,
        'ST101.EM02');
  });
}
