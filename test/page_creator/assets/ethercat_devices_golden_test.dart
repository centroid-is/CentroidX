import 'dart:async' show Completer;
import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/ethercat_devices.dart';
import 'package:tfc/page_creator/assets/ethercat_subdevice.dart';
import 'package:tfc/page_creator/assets/ethercat_subdevice_pane.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/theme.dart';
import 'package:tfc_dart/core/state_man.dart' show StateMan;

import '../../helpers/golden_fonts.dart';
import '../../helpers/golden_platform.dart';
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
  // These goldens are almost entirely small text — a dozen columns of names,
  // models and counters — which is exactly the case that used to need a raised
  // tolerance: CoreText rasterised it a hair differently on the CI runner
  // (macOS 26) than on a developer Mac (macOS 15), moving 43 px of the table on
  // images nobody had touched. Rendering on Linux removes that gap, so this is
  // back to the 0.01% default along with the rest of the suite.
  useTolerantGoldenComparator();

  group('EtherCAT devices', skip: goldenSkip, () {
    testWidgets('two masters, one of everything the table shows',
        (tester) async {
      await loadGoldenFonts();
      await tester.pumpWidget(frame(EcDeviceTableView(plcs: ecSamplePlcs())));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_devices_table.png'));
    });

    testWidgets('filtered to the rows that need somebody', (tester) async {
      await loadGoldenFonts();
      await tester.pumpWidget(frame(EcDeviceTableView(
        plcs: ecSamplePlcs(),
        initialProblemsOnly: true,
      )));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_devices_problems.png'));
    });

    testWidgets('narrow: model and clean-for give way first', (tester) async {
      await loadGoldenFonts();
      await tester.pumpWidget(
          frame(EcDeviceTableView(plcs: ecSamplePlcs()), width: 560));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_devices_narrow.png'));
    });

    testWidgets('config form: size and position like every other asset',
        (tester) async {
      await loadGoldenFonts();
      await tester.pumpWidget(frame(
        Padding(
          padding: const EdgeInsets.all(16),
          child: Builder(builder: EtherCatDeviceTableConfig().configure),
        ),
        width: 520,
        height: 460,
      ));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_devices_config.png'));
    });

    testWidgets('closed groups: one master shut, the other PLC open',
        (tester) async {
      await loadGoldenFonts();
      await tester.pumpWidget(frame(EcDeviceTableView(plcs: ecSamplePlcs())));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ec-row-m:PLC 1/Device 1')));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_devices_collapsed.png'));
    });

    testWidgets('config form: PLCs and their masters, each with a drag handle',
        (tester) async {
      // Taller than the default test window, or the frame is cut off.
      tester.view.physicalSize = const Size(700, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await loadGoldenFonts();
      final config = EtherCatDeviceTableConfig(plcs: [
        EcPlcConfig(label: 'PLC 1', masters: [
          EcBusConfig(
              label: 'Device 1', diagKey: 'ect1.diag', infoKey: 'ect1.info'),
          EcBusConfig(
              label: 'Device 2', diagKey: 'ect2.diag', infoKey: 'ect2.info'),
        ]),
        EcPlcConfig(label: 'PLC 2', masters: [
          EcBusConfig(
              label: 'Device 1', diagKey: 'plc2.diag', infoKey: 'plc2.info'),
        ]),
      ]);
      await tester.pumpWidget(ProviderScope(
        // The key fields only use the server to suggest keys; a server that
        // never answers draws them exactly as a connected one does.
        overrides: [
          stateManProvider.overrideWith((_) => Completer<StateMan>().future),
        ],
        child: frame(
          Padding(
            padding: const EdgeInsets.all(16),
            child: Builder(builder: config.configure),
          ),
          width: 520,
          height: 1100,
        ),
      ));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_devices_config_plcs.png'));
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
