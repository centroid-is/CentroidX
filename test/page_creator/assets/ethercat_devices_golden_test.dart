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
import 'ethercat_neutral_sample.dart';

const _key = Key('ethercat_devices');

/// The table's own header row height, as a ceiling a single line must stay
/// under. Spelled out here rather than imported because the widths live in a
/// private class; if the table's row height ever changes, this is the one
/// place the guard has to follow it to.
abstract final class _Col {
  static const rowHeightGuard = 22.0;
}

/// A table is nothing but words and figures; under Ahem every cell is a
/// solid block and the golden proves the grid while saying nothing about it.
Future<void> loadRealFont() async {
  final data = File('lib/fonts/dejavu-sans/DejaVuSans.ttf')
      .readAsBytesSync()
      .buffer
      .asByteData();
  for (final family in ['Roboto', 'dejavu-sans']) {
    await (FontLoader(family)..addFont(Future.value(data))).load();
  }
}

Widget frame(Widget child,
    {double width = 900, double height = 420, ThemeData? theme}) {
  final (light, _) = solarized();
  return MaterialApp(
    theme: theme ?? light,
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

    testWidgets('started collapsed: each PLC a summary, one opened by a tap',
        (tester) async {
      await loadGoldenFonts();
      await tester.pumpWidget(frame(EcDeviceTableView(
        plcs: ecSamplePlcs(),
        initialCollapsed: true,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ec-row-p:PLC 2')));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_devices_start_collapsed.png'));
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

    // The pane's own chrome, which the three above never show: they golden the
    // body alone. The sample is invented rather than `ecSampleBuses()` — these
    // images exist to show a button in a header, and there is no reason for
    // equipment names to be in them.
    testWidgets('subdevice pane: the header explains the counters',
        (tester) async {
      await loadGoldenFonts();
      final b = neutralEcBus();
      await tester.pumpWidget(frame(
        EcSubDevicePaneView(
          bus: b,
          subdevice: b.at(2),
          position: 2,
          plcLabel: 'PLC 1',
          onReset: (_) async {},
        ),
        width: 380,
        height: 620,
      ));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_subdevice_pane_help.png'));
    });

    testWidgets('subdevice pane: the help button shows it has focus',
        (tester) async {
      await loadGoldenFonts();
      final b = neutralEcBus();
      await tester.pumpWidget(frame(
        EcSubDevicePaneView(
          bus: b,
          subdevice: b.at(2),
          position: 2,
          plcLabel: 'PLC 1',
          onReset: (_) async {},
        ),
        width: 380,
        height: 620,
      ));
      await tester.pumpAndSettle();
      // Read from below the button's own Focus: an IconButton given no
      // `focusNode` builds one internally, so the widget's field is null.
      Focus.maybeOf(tester.element(find.descendant(
        of: find.byKey(kEcCounterHelpKey),
        matching: find.byIcon(Icons.info_outline),
      )))!
          .requestFocus();
      await tester.pumpAndSettle();
      await expectLater(
          find.byKey(_key),
          matchesGoldenFile(
              'goldens/ethercat_subdevice_pane_help_focused.png'));
    });

    for (final (name, dark) in [('light', false), ('dark', true)]) {
      testWidgets('the counter explanation, $name', (tester) async {
        await loadGoldenFonts();
        final (lightTheme, darkTheme) = solarized();
        await tester.pumpWidget(frame(
          // The insets the dialog would supply, so the golden is the
          // explanation as an operator sees it rather than text against an
          // edge.
          const Material(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: EcCounterHelpText(),
            ),
          ),
          theme: dark ? darkTheme : lightTheme,
          width: 440,
          height: 420,
        ));
        await tester.pumpAndSettle();
        await expectLater(find.byKey(_key),
            matchesGoldenFile('goldens/ethercat_counter_help_$name.png'));
      });
    }
  });

  // Not a golden: this one has to fail on every platform, because the header
  // it guards is a hand-tuned constant width and 'Link loss' is nearly twice
  // the string 'Drops' was. A clipped or wrapped header is worse than the old
  // word, and at the table's row height a wrap is a render overflow rather
  // than something anybody would notice in review.
  testWidgets('the Link loss header fits its column at normal width',
      (tester) async {
    await loadRealFont();
    await tester.pumpWidget(frame(EcDeviceTableView(plcs: ecSamplePlcs())));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    for (final header in ['CRC', 'Link loss', 'Clean for']) {
      final finder = find.text(header).first;
      expect(finder, findsOneWidget, reason: 'missing the $header header');
      final box = tester.renderObject<RenderBox>(finder);
      final painter = TextPainter(
        text: TextSpan(
            text: header, style: tester.widget<Text>(finder).style),
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
        maxLines: 1,
      )..layout();
      final needed = painter.width;
      painter.dispose();
      expect(needed, lessThanOrEqualTo(box.size.width + 0.5),
          reason: '$header needs ${needed.toStringAsFixed(1)} px but its '
              'column gives it ${box.size.width.toStringAsFixed(1)} px');
      // One line, not two: the header row is 22 px tall and a wrapped cell
      // overflows it.
      expect(box.size.height, lessThan(_Col.rowHeightGuard),
          reason: '$header wrapped onto a second line');
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
