import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/beckhoff.dart';
import 'package:tfc/page_creator/assets/ethercat_subdevice.dart';
import 'package:tfc/page_creator/assets/ethercat_subdevice_editor.dart';
import 'package:tfc/page_creator/assets/registry.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/theme.dart';

import '../../helpers/ethercat_fake_state_man.dart';
import '../../helpers/ethercat_fixtures.dart';
import '../../helpers/golden_platform.dart';
import '../../helpers/golden_tolerance.dart';

const _key = Key('ethercat_subdevice_binding_editor');

Future<void> loadRealFont() async {
  final data = File('lib/fonts/roboto-mono/RobotoMono-Regular.ttf')
      .readAsBytesSync()
      .buffer
      .asByteData();
  for (final family in ['Roboto', 'roboto-mono']) {
    await (FontLoader(family)..addFont(Future.value(data))).load();
  }
}

void main() {
  useTolerantGoldenComparator();

  group('EtherCAT subdevice binding',
      skip: goldenSkip, () {
    testWidgets('a slice bound to its subdevice by name', (tester) async {
      await loadRealFont();
      final sm = EcFakeStateMan(mappings: ecDevice1Mappings())
        ..push(
            'ect1.diag',
            array([
              diag(),
              diag(),
              diag(crcPort: const [7, 0, 0, 0], crcStable: 120),
            ]))
        ..push(
            'ect1.info',
            array([
              info('ST101.A1.01 (EL6070)', model: 'EL6070', addr: 1001),
              info('ST101.A1.02 (EL9222-5500)',
                  model: 'EL9222-5500', addr: 1002, prev: 1001),
              info('ST101.A1.03 (EL1008)',
                  model: 'EL1008', addr: 1003, prev: 1002),
            ]));
      final slice = (AssetRegistry.defaultFactories[BeckhoffEL1008Config]!()
          as BeckhoffEL1008Config)
        ..nameOrId = 'A1.03'
        ..ecSubDevice = EcSubDeviceBinding(
          diagKey: 'ect1.diag',
          infoKey: 'ect1.info',
          position: 3,
          name: 'ST101.A1.03',
        );
      final (light, _) = solarized();
      await tester.pumpWidget(ProviderScope(
        overrides: [stateManProvider.overrideWith((_) async => sm)],
        child: MaterialApp(
          theme: light,
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: _key,
                // A Material, not a coloured Container: the expansion tile's
                // header is a ListTile, which paints its ink on the nearest
                // Material and asserts when a coloured box hides it.
                child: Material(
                  color: light.colorScheme.surface,
                  child: Container(
                    width: 380,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: EcSubDeviceBindingEditor(asset: slice),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_subdevice_binding_editor.png'));
    });
  });
}
