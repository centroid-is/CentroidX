import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';
import 'package:tfc/page_creator/assets/ethercat_command.dart';
import 'package:tfc/page_creator/assets/ethercat_devices.dart';
import 'package:tfc/page_creator/assets/link_anchors.dart';
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
  /// Mounted the way a page mounts it: inside a [PageAssetsScope], which is
  /// what tells the table it is on a page rather than being drawn as a
  /// palette thumbnail — and so the only place it may go looking for the
  /// station's masters.
  Widget wrap(Widget child, _FakeStateMan sm) => ProviderScope(
        overrides: [stateManProvider.overrideWith((_) async => sm)],
        child: MaterialApp(
          home: Scaffold(
            body: PageAssetsScope(
              assets: const [],
              canvas: const Size(900, 400),
              child: SizedBox(width: 900, height: 400, child: child),
            ),
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
        config: EtherCatDeviceTableConfig(plcs: [
          EcPlcConfig(masters: [
            EcBusConfig(label: 'Device 1', diagKey: 'd1', infoKey: 'i1'),
          ]),
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
          plcs: [
            EcPlcConfig(masters: [
              EcBusConfig(label: 'Device 1', diagKey: 'd1', infoKey: 'i1'),
            ]),
          ],
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

  testWidgets('the config form resizes and moves the table', (tester) async {
    final config = EtherCatDeviceTableConfig();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: config.configure)),
    ));

    Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label);
    await tester.enterText(field('Width %'), '40');
    await tester.enterText(field('Height %'), '25');
    await tester.enterText(field('X 0-100%'), '10');
    await tester.pump();

    expect(config.size.width, closeTo(0.40, 1e-9));
    expect(config.size.height, closeTo(0.25, 1e-9));
    expect(config.coordinates.x, closeTo(0.1, 1e-9));
  });

  testWidgets('the table lists PLCs and their masters in the configured order',
      (tester) async {
    final sm = _FakeStateMan()
      ..push('d1', _diag())
      ..push('i1', _info())
      ..push('d2', _diag())
      ..push('i2', _info());
    await tester.pumpWidget(wrap(
      EtherCatDeviceTable(
        config: EtherCatDeviceTableConfig(plcs: [
          EcPlcConfig(label: 'PLC B', masters: [
            EcBusConfig(label: 'Device 1', diagKey: 'd2', infoKey: 'i2'),
          ]),
          EcPlcConfig(label: 'PLC A', masters: [
            EcBusConfig(label: 'Device 1', diagKey: 'd1', infoKey: 'i1'),
          ]),
        ]),
      ),
      sm,
    ));
    await tester.pump();
    await tester.pump();

    double top(String key) =>
        tester.getTopLeft(find.byKey(ValueKey('ec-row-$key'))).dy;
    expect(top('p:PLC B'), lessThan(top('m:PLC B/Device 1')));
    expect(top('m:PLC B/Device 1'), lessThan(top('p:PLC A')));
    expect(top('p:PLC A'), lessThan(top('m:PLC A/Device 1')));
    // Both PLCs have a Device 1, and each lists its own subdevices.
    expect(find.text('SAFEOP'), findsNWidgets(2));
  });

  testWidgets('one unnamed PLC draws no PLC row', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: 400,
          child: EcDeviceTableView(
            plcs: [EcPlc('', ecSampleBuses())],
          ),
        ),
      ),
    ));
    expect(find.byKey(const ValueKey('ec-row-p:')), findsNothing);
    expect(find.byKey(const ValueKey('ec-row-m:/Device 1')), findsOneWidget);
  });

  testWidgets('a tap closes a PLC or a master, and a search reopens it',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: 600,
          child: EcDeviceTableView(plcs: ecSamplePlcs()),
        ),
      ),
    ));
    expect(find.text('EL6070'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ec-row-m:PLC 1/Device 1')));
    await tester.pump();
    expect(find.text('EL6070'), findsNothing);
    expect(find.byKey(const ValueKey('ec-row-p:PLC 2')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ec-row-p:PLC 2')));
    await tester.pump();
    expect(find.byKey(const ValueKey('ec-row-m:PLC 2/Device 2')), findsNothing);

    // Part of a model: the box holds 'EL607', so only the row matches exactly.
    await tester.enterText(find.byType(TextField), 'EL607');
    await tester.pump();
    expect(find.text('EL6070'), findsOneWidget);
    // Nothing under PLC 2 matched, so it stays as it was left.
    expect(find.byKey(const ValueKey('ec-row-m:PLC 2/Device 2')), findsNothing);
  });

  test('a page saved with a flat list of masters opens as one unnamed PLC', () {
    final saved = EtherCatDeviceTableConfig().toJson()
      ..remove('plcs')
      ..['buses'] = [
        {'label': 'Device 1', 'diagKey': 'd1', 'infoKey': 'i1'},
        {'label': 'Device 2', 'diagKey': 'd2', 'infoKey': 'i2'},
      ];
    final config = EtherCatDeviceTableConfig.fromJson(
        jsonDecode(jsonEncode(saved)) as Map<String, dynamic>);
    expect(config.plcs, hasLength(1));
    expect(config.plcs.single.label, '');
    expect([for (final m in config.masters) m.diagKey], ['d1', 'd2']);
    expect(config.allKeys, ['d1', 'i1', 'd2', 'i2']);

    final json = jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>;
    expect(json.containsKey('buses'), isFalse);
    final again = EtherCatDeviceTableConfig.fromJson(json);
    expect([for (final m in again.masters) m.label], ['Device 1', 'Device 2']);
  });

  Finder labelled(String label) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == label);

  Future<void> pumpForm(
      WidgetTester tester, EtherCatDeviceTableConfig config) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      // A server that never answers. The key fields list the keys of the one
      // they are given as they build, and the fake has no key list.
      overrides: [
        stateManProvider.overrideWith((_) => Completer<StateMan>().future),
      ],
      child: MaterialApp(
        home: Scaffold(body: Builder(builder: config.configure)),
      ),
    ));
    await tester.pump();
  }

  /// The drag handle on the card for [model] — its own, not one of its
  /// masters': the card's header comes first.
  Finder handleOf(Object model) => find
      .descendant(
          of: find.byKey(ObjectKey(model)),
          matching: find.byIcon(Icons.drag_indicator))
      .first;

  /// Drags [handle] to just above [target], in steps: the list only moves its
  /// gap once the drag has travelled, and one long jump skips straight past.
  Future<void> dragAbove(
      WidgetTester tester, Finder handle, Finder target) async {
    final from = tester.getCenter(handle);
    final to = tester.getCenter(target);
    final gesture = await tester.startGesture(from);
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(Offset(0, (to.dy - from.dy - 40) / 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('the config form drags a PLC above another', (tester) async {
    final a = EcPlcConfig(label: 'PLC 1', masters: [EcBusConfig()]);
    final b = EcPlcConfig(label: 'PLC 2', masters: [EcBusConfig()]);
    final config = EtherCatDeviceTableConfig(plcs: [a, b]);
    await pumpForm(tester, config);

    await dragAbove(tester, handleOf(b), handleOf(a));
    expect(config.plcs, [b, a]);
    expect(
      [
        for (final t in tester.widgetList<TextField>(labelled('PLC')))
          t.controller!.text,
      ],
      ['PLC 2', 'PLC 1'],
    );
  });

  testWidgets(
      'the config form drags a master within its PLC, and moves one to another',
      (tester) async {
    final one = EcBusConfig(label: 'Device 1', diagKey: 'd1');
    final two = EcBusConfig(label: 'Device 2', diagKey: 'd2');
    final three = EcBusConfig(label: 'Device 3', diagKey: 'd3');
    final a = EcPlcConfig(label: 'PLC 1', masters: [one, two]);
    final b = EcPlcConfig(label: 'PLC 2', masters: [three]);
    await pumpForm(tester, EtherCatDeviceTableConfig(plcs: [a, b]));

    await dragAbove(tester, handleOf(two), handleOf(one));
    expect(a.masters, [two, one]);
    expect(b.masters, [three]);
    // Each card kept its own fields through the move: the top one is now
    // Device 2's, not Device 1's text left behind in the slot.
    await tester.enterText(labelled('Master').first, 'Line A');
    expect(two.label, 'Line A');
    expect(one.label, 'Device 1');

    await tester.tap(find.descendant(
        of: find.byKey(ObjectKey(one)),
        matching: find.byTooltip('Move to another PLC')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<EcPlcConfig>, 'PLC 2'));
    await tester.pumpAndSettle();
    expect(a.masters, [two]);
    expect(b.masters, [three, one]);
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
