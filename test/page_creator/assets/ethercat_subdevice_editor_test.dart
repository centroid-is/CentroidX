import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/beckhoff.dart';
import 'package:tfc/page_creator/assets/ethercat_subdevice.dart';
import 'package:tfc/page_creator/assets/ethercat_subdevice_editor.dart';
import 'package:tfc/page_creator/assets/registry.dart';
import 'package:tfc/providers/state_man.dart';

import '../../helpers/ethercat_fake_state_man.dart';
import '../../helpers/ethercat_fixtures.dart';

DynamicValue _info() => array([
      info('ST101.A1.01 (EL6070)', model: 'EL6070', addr: 1001),
      info('ST101.A1.02 (EL9222-5500)', model: 'EL9222-5500', addr: 1002),
      info('ST101.A1.03 (EL1008)', model: 'EL1008', addr: 1003),
    ]);

DynamicValue _diag() => array([diag(), diag(), diag()]);

BeckhoffEL1008Config _slice(String name) =>
    (AssetRegistry.defaultFactories[BeckhoffEL1008Config]!()
        as BeckhoffEL1008Config)
      ..nameOrId = name;

Widget _wrap(EcFakeStateMan sm, Widget child) => ProviderScope(
      overrides: [stateManProvider.overrideWith((_) async => sm)],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(width: 380, child: child),
          ),
        ),
      ),
    );

EcFakeStateMan _station() => EcFakeStateMan(mappings: ecDevice1Mappings())
  ..push('ect1.diag', _diag())
  ..push('ect1.info', _info());

void main() {
  testWidgets('find by name binds to the subdevice the PLC calls that',
      (tester) async {
    final slice = _slice('A1.03');
    await tester.pumpWidget(_wrap(_station(), EcSubDeviceBindingEditor(asset: slice)));
    await tester.pump();
    await tester.tap(find.text('EtherCAT subdevice'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Find by name'));
    await tester.pumpAndSettle();

    final b = slice.ecSubDevice!;
    expect(b.diagKey, 'ect1.diag');
    expect(b.infoKey, 'ect1.info');
    expect(b.position, 3);
    expect(b.name, 'ST101.A1.03');
    expect(find.textContaining('Bound to ST101.A1.03 on Device 1'),
        findsOneWidget);
    expect(find.text('In OP, no recent errors.'), findsOneWidget);
  });

  testWidgets('a name no subdevice has says so and binds nothing', (tester) async {
    final slice = _slice('Z9.99');
    await tester.pumpWidget(_wrap(_station(), EcSubDeviceBindingEditor(asset: slice)));
    await tester.pump();
    await tester.tap(find.text('EtherCAT subdevice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find by name'));
    await tester.pumpAndSettle();

    expect(slice.ecSubDevice, isNull);
    expect(find.textContaining('No subdevice on any master is called "Z9.99"'),
        findsOneWidget);
  });

  testWidgets('a bound subdevice that has moved offers to follow it',
      (tester) async {
    // Bound to position 1 by name, but the PLC now has that name at 3.
    final slice = _slice('A1.03')
      ..ecSubDevice = EcSubDeviceBinding(
          diagKey: 'ect1.diag',
          infoKey: 'ect1.info',
          position: 1,
          name: 'ST101.A1.03');
    await tester.pumpWidget(_wrap(_station(), EcSubDeviceBindingEditor(asset: slice)));
    await tester.pumpAndSettle();

    expect(find.textContaining('is now #3 (was #1)'), findsOneWidget);
    await tester.tap(find.textContaining('follow it'));
    await tester.pumpAndSettle();
    expect(slice.ecSubDevice!.position, 3);
    expect(find.textContaining('follow it'), findsNothing);
  });

  testWidgets('unbind leaves nothing behind in the saved asset',
      (tester) async {
    final slice = _slice('A1.03')
      ..ecSubDevice = EcSubDeviceBinding(
          diagKey: 'ect1.diag', infoKey: 'ect1.info', position: 3);
    await tester.pumpWidget(_wrap(_station(), EcSubDeviceBindingEditor(asset: slice)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unbind'));
    await tester.pumpAndSettle();
    expect(slice.ecSubDevice, isNull);
    expect(slice.toJson().containsKey('ecSubDevice'), isFalse);
  });
}
