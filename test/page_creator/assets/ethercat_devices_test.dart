import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';
import 'package:tfc/page_creator/assets/ethercat_command.dart';
import 'package:tfc/page_creator/assets/ethercat_devices.dart';
import 'package:tfc/page_creator/assets/ethercat_subdevice.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/ethercat_fixtures.dart';

/// Two subdevices in OP and one out of it, on one master.
DynamicValue _info() => array([
      info('ST101.A1.01 (EL6070)', model: 'EL6070', addr: 1001),
      info('CVS01.CN01.FD01 (ATV320 EtherCAT)',
          model: 'ATV320 EtherCAT', addr: 1002, prev: 1001),
      info('CVS01.CN02.FD01 (ATV320 EtherCAT)',
          model: 'ATV320 EtherCAT', addr: 1003, prev: 1002),
      emptyInfo(),
    ]);

DynamicValue _diag() => array([
      diag(),
      diag(),
      diag(deviceState: 4),
      diag(deviceState: 0),
    ]);

void main() {
  Widget wrap(Widget child, _FakeStateMan sm) => ProviderScope(
        overrides: [stateManProvider.overrideWith((_) async => sm)],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 900, height: 400, child: child),
          ),
        ),
      );

  testWidgets('lists the subdevices by their PLC names, with a summary',
      (tester) async {
    final sm = _FakeStateMan()
      ..push('d1', _diag())
      ..push('i1', _info());
    await tester.pumpWidget(wrap(
      EtherCatDeviceTable(
        config: EtherCatDeviceTableConfig(buses: [
          EcBusConfig(label: 'Device 1', diagKey: 'd1', infoKey: 'i1'),
        ]),
      ),
      sm,
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('ST101.A1.01'), findsOneWidget);
    expect(find.text('CVS01.CN02.FD01'), findsOneWidget);
    expect(find.text('SAFEOP'), findsOneWidget);
    expect(find.textContaining('3 devices'), findsOneWidget);
    // The empty tail of the 128-slot array is not a device.
    expect(find.text('#4'), findsNothing);
  });

  testWidgets('problems only hides the rows that are fine', (tester) async {
    final sm = _FakeStateMan()
      ..push('d1', _diag())
      ..push('i1', _info());
    await tester.pumpWidget(wrap(
      EtherCatDeviceTable(
        config: EtherCatDeviceTableConfig(
          buses: [EcBusConfig(label: 'Device 1', diagKey: 'd1', infoKey: 'i1')],
          problemsOnly: true,
        ),
      ),
      sm,
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('ST101.A1.01'), findsNothing);
    expect(find.text('CVS01.CN02.FD01'), findsOneWidget);

    await tester.tap(find.text('Problems only'));
    await tester.pump();
    expect(find.text('ST101.A1.01'), findsOneWidget);
  });

  testWidgets('with no masters configured, finds them in the key mappings',
      (tester) async {
    final sm = _FakeStateMan(
      mappings: KeyMappings(nodes: {
        'ect1.diag': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(
                namespace: 4, identifier: 'ECT_Diag.Device_1_Diag')),
        'ect1.info': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(
                namespace: 4, identifier: 'ECT_Diag.Device_1_SlaveInfo')),
      }),
    )
      ..push('ect1.diag', _diag())
      ..push('ect1.info', _info());
    await tester.pumpWidget(
        wrap(EtherCatDeviceTable(config: EtherCatDeviceTableConfig()), sm));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('CVS01.CN01.FD01'), findsOneWidget);
    expect(find.textContaining('Device 1'), findsWidgets);
    expect(find.textContaining('Sample'), findsNothing);
  });

  testWidgets('with nothing mapped, shows a labelled sample', (tester) async {
    await tester.pumpWidget(wrap(
        EtherCatDeviceTable(config: EtherCatDeviceTableConfig()),
        _FakeStateMan()));
    await tester.pump();
    expect(find.textContaining('Sample'), findsOneWidget);
    // A picture of the table, not a working one. The page editor's palette
    // shows this tile next to its own search box, and a second text field on
    // screen breaks every `enterText(find.byType(TextField))` in the editor's
    // tests — which is how this was found.
    expect(find.byType(TextField), findsNothing);
    expect(find.text('ST101.A1.01'), findsOneWidget);
  });

  group('reset commands', () {
    Future<void> press(
        WidgetTester tester, _FakeStateMan sm, EcCommandWriter writer) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [stateManProvider.overrideWith((_) async => sm)],
        child: MaterialApp(
          home: Consumer(builder: (context, ref, _) {
            return TextButton(
              onPressed: () => writer.setCommand(ref,
                  diagKey: 'd1', position: 2, member: EcDiagFields.resetCrc),
              child: const Text('reset'),
            );
          }),
        ),
      ));
      await tester.tap(find.text('reset'));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('the default writes one BOOL, on the member node',
        (tester) async {
      final sm = _FakeStateMan();
      await press(tester, sm, const EcMemberCommandWriter());
      expect(sm.writes, hasLength(1));
      expect(sm.writes.single.key, 'd1[2].p_cmd_resetCrcCounter');
      expect(sm.writes.single.value.asBool, isTrue);
    });

    testWidgets('the array writer changes exactly one member of one element',
        (tester) async {
      final sm = _FakeStateMan()..push('d1', _diag());
      await press(tester, sm, const EcArrayCommandWriter());
      expect(sm.writes, hasLength(1));
      final written = sm.writes.single.value;
      expect(written[1][EcDiagFields.resetCrc].asBool, isTrue);
      expect(written[0][EcDiagFields.resetCrc].asBool, isFalse);
      expect(written[2][EcDiagFields.resetCrc].asBool, isFalse);
    });
  });
}

class _FakeStateMan implements StateMan {
  _FakeStateMan({KeyMappings? mappings})
      : _mappings = mappings ?? KeyMappings(nodes: {});

  final KeyMappings _mappings;
  final Map<String, BehaviorSubject<DynamicValue>> _streams = {};
  final List<({String key, DynamicValue value})> writes = [];

  void push(String key, DynamicValue value) =>
      _streams.putIfAbsent(key, BehaviorSubject<DynamicValue>.new).add(value);

  @override
  KeyMappings get keyMappings => _mappings;

  @override
  String resolveKey(String key) => key;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async =>
      _streams.putIfAbsent(key, BehaviorSubject<DynamicValue>.new).stream;

  @override
  Future<DynamicValue> read(String key) async => _streams[key]!.value;

  @override
  Future<void> write(String key, DynamicValue value) async =>
      writes.add((key: key, value: value));

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      '_FakeStateMan: ${invocation.memberName} not implemented');
}
