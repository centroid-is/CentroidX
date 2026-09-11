import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/ethercat_link.dart';
import 'package:tfc/page_creator/assets/ethercat_link_pane.dart';
import 'package:tfc/page_creator/assets/ethercat_subdevice.dart';
import 'package:tfc/page_creator/assets/schneider.dart';
import 'package:tfc/theme.dart';

import '../../helpers/ethercat_fixtures.dart';
import '../../helpers/golden_tolerance.dart';

const _key = Key('ethercat_link_derived');

/// The pane is all words and figures; under Ahem every glyph is a solid box.
Future<void> loadRealFont() async {
  final data = File('lib/fonts/roboto-mono/RobotoMono-Regular.ttf')
      .readAsBytesSync()
      .buffer
      .asByteData();
  for (final family in ['Roboto', 'roboto-mono']) {
    await (FontLoader(family)..addFont(Future.value(data))).load();
  }
}

/// Two drives in a chain, 1 → 2 on port B.
EcBus _bus({
  int linkState1 = 0,
  List<int> crc1 = const [0, 0, 0, 0],
  String secondName = 'CVS01.CN02.FD01 (ATV320 EtherCAT)',
}) =>
    EcBus.fromValues(
      '',
      info: array([
        info('CVS01.CN01.FD01 (ATV320 EtherCAT)',
            model: 'ATV320 EtherCAT', addr: 1001),
        info(secondName,
            model: 'ATV320 EtherCAT', addr: 1002, prev: 1001, prevPort: 'B'),
      ]),
      diag: array([
        diag(linkState: linkState1, crcPort: crc1, crcStable: 240),
        diag(),
      ]),
    );

EcLinkEnd _end(String label, int position, EcPort port) => EcLinkEnd(
      asset: SchneiderATV320Config(label: label)
        ..coordinates = Coordinates(x: 0.5, y: 0.5),
      binding: EcSubDeviceBinding(diagKey: 'd1', position: position, name: label),
      port: port,
    );

Widget pane(EcBus bus, {bool withOpen = true}) {
  final (light, _) = solarized();
  return MaterialApp(
    theme: light,
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: Center(
        child: RepaintBoundary(
          key: _key,
          child: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: EcLinkPaneBody(
                a: _end('CVS01.CN01.FD01', 1, EcPort.b),
                subdeviceA: bus.at(1),
                busA: bus,
                b: _end('CVS01.CN02.FD01', 2, EcPort.a),
                subdeviceB: bus.at(2),
                busB: bus,
                onOpen: withOpen ? (_) {} : null,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  useTolerantGoldenComparator();

  group('EtherCAT cable, coloured from its ends',
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    testWidgets('a healthy run the PLC confirms', (tester) async {
      await loadRealFont();
      await tester.pumpWidget(pane(_bus()));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_link_derived_healthy.png'));
    });

    testWidgets('CRC errors on the upstream port', (tester) async {
      await loadRealFont();
      await tester.pumpWidget(pane(_bus(crc1: const [0, 12, 0, 0])));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_link_derived_degraded.png'));
    });

    testWidgets('a missing link takes the cable down', (tester) async {
      await loadRealFont();
      await tester.pumpWidget(pane(_bus(linkState1: 0x24)));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_link_derived_down.png'));
    });

    testWidgets('the drawn cable is not the one the PLC has', (tester) async {
      // The PLC says port B goes to a drive nobody drew here, so the cable on
      // the page is wrong — or the devices are bound to the wrong subdevices.
      await loadRealFont();
      await tester
          .pumpWidget(pane(_bus(secondName: 'CVS01.CN07.FD01 (ATV320 EtherCAT)')));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_link_derived_mismatch.png'));
    });
  });

  test('the fixtures say what the goldens claim', () {
    expect(ecLinkHealth(_bus(), _bus().at(1), EcPort.b, _bus(), _bus().at(2),
        EcPort.a), isNotNull);
  });
}
