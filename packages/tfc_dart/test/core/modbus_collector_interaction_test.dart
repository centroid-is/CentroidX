/// The merge-order hazard between the two fixes, tested rather than assumed.
///
/// Before the _onPollTick fix, a failed Modbus poll still published — it
/// emitted `DynamicValue(value: null)`, a NON-null object. That is what kept
/// the collector's `latestValue!` alive: latestValue was assigned a non-null
/// DynamicValue on the very first (failed) poll, so the bang never fired.
///
/// After the _onPollTick fix a failed poll publishes NOTHING, so latestValue
/// stays null for as long as the device is silent, and the sample timer's
/// bang would fire on its first tick. The Modbus fix therefore INCREASES
/// exposure to the collector bug, and the collector guard must land first or
/// together — never after.
///
/// Both fixes are present here. This test exists to keep them together: it
/// fails if the collector guard is ever reverted while the Modbus fix stands.
@TestOn('vm')
library;

import 'dart:async';

import 'package:modbus_client/modbus_client.dart';
import 'package:modbus_client_tcp/modbus_client_tcp.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/modbus_client_wrapper.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:tfc_dart/core/state_man.dart';

/// A device that never answers. The socket is up; every read times out.
class SilentDevice extends ModbusClientTcp {
  SilentDevice()
      : super('mock',
            serverPort: 0, connectionMode: ModbusConnectionMode.doNotConnect);

  bool _connected = false;

  @override
  bool get isConnected => _connected;

  @override
  Future<bool> connect() async {
    _connected = true;
    return true;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }

  @override
  Future<ModbusResponseCode> send(ModbusRequest request) async =>
      ModbusResponseCode.requestTimeout;
}

class CountingDatabase implements Database {
  int inserts = 0;

  @override
  Future<void> registerRetentionPolicy(String t, RetentionPolicy r) async {}

  @override
  Future<void> insertTimeseriesData(String t, DateTime time, dynamic v) async {
    inserts++;
  }

  @override
  Future<List<TimeseriesData<dynamic>>> queryTimeseriesData(
          String tableName, DateTime to,
          {String? orderBy = 'time ASC', DateTime? from}) async =>
      [];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  test(
      'a sampled Modbus key on a device that never answers: no throw, no '
      'fabricated rows', () async {
    const spec = ModbusRegisterSpec(
      key: 'weight',
      registerType: ModbusElementType.holdingRegister,
      address: 0,
      dataType: ModbusDataType.uint16,
      pollGroup: 'fast',
    );

    final db = CountingDatabase();
    final stateMan = await OpcUaStateMan.create(
      config: StateManConfig(opcua: []),
      keyMappings: KeyMappings(nodes: {}),
    );
    addTearDown(() =>
        stateMan.close().timeout(const Duration(seconds: 5), onTimeout: () {}));

    final errors = <Object>[];
    late ModbusClientWrapper wrapper;
    late Collector collector;

    await runZonedGuarded(() async {
      wrapper = ModbusClientWrapper('h', 502, 1,
          clientFactory: (h, p, u) => SilentDevice());
      wrapper.addPollGroup('fast', const Duration(milliseconds: 40));
      final adapter = ModbusDeviceClientAdapter(wrapper,
          specs: const {'weight': spec}, serverAlias: 'plc');

      collector = Collector(
        config: CollectorConfig(collect: true),
        stateMan: stateMan,
        database: db,
      );
      // A SAMPLED collection: this is the combination that matters, because
      // only the sample timer dereferences latestValue.
      await collector.collectEntryImpl(
        CollectEntry(
            key: 'weight',
            name: 'weight',
            sampleInterval: const Duration(milliseconds: 30)),
        adapter.subscribe('weight'),
      );

      wrapper.connect();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }, (e, _) => errors.add(e));
    addTearDown(() {
      collector.close();
      wrapper.dispose();
    });

    expect(errors, isEmpty,
        reason: 'The Modbus fix stops a failed poll publishing, so '
            'latestValue stays null while the device is silent — and the '
            'collector sample timer must survive that. If this fails with a '
            'null-check TypeError, the collector guard has been reverted '
            'while the _onPollTick fix stands, which is precisely the '
            'merge order that must never ship. Errors: $errors');
    expect(db.inserts, 0,
        reason: 'A device that has never answered must not produce rows.');
  });
}
