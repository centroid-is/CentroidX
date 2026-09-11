/// Does a dead Modbus device write fabricated history?
///
/// The full production chain, no shortcuts: ModbusClientWrapper poll ->
/// ModbusDeviceClientAdapter.subscribe -> Collector.collectEntryImpl ->
/// Database.insertTimeseriesData.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:modbus_client/modbus_client.dart';
import 'package:modbus_client_tcp/modbus_client_tcp.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:test/test.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/modbus_client_wrapper.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:tfc_dart/core/state_man.dart';

/// A device that answers correctly and then stops answering entirely —
/// the cable pulled, the switch port dying, the PLC halting.
class DyingModbusClient extends ModbusClientTcp {
  DyingModbusClient()
      : super('mock',
            serverPort: 0, connectionMode: ModbusConnectionMode.doNotConnect);

  bool _connected = false;

  /// Flip to stop answering. The socket stays "up".
  bool dead = false;

  /// The value the device reports while it is alive.
  int liveValue = 4242;

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
  Future<ModbusResponseCode> send(ModbusRequest request) async {
    if (dead) return ModbusResponseCode.requestTimeout;
    if (request is ModbusReadGroupRequest) {
      final data = Uint8List(request.elementGroup.addressRange * 2);
      ByteData.view(data.buffer).setUint16(0, liveValue);
      request.internalSetElementData(data);
    } else if (request is ModbusReadRequest) {
      final bytes = Uint8List(request.element.byteCount);
      ByteData.view(bytes.buffer).setUint16(0, liveValue);
      request.element.setValueFromBytes(bytes);
    }
    return ModbusResponseCode.requestSucceed;
  }
}

class RecordingDatabase implements Database {
  final rows = <dynamic>[];

  @override
  Future<void> registerRetentionPolicy(String t, RetentionPolicy r) async {}

  @override
  Future<void> insertTimeseriesData(
      String tableName, DateTime time, dynamic value) async {
    rows.add(value);
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
  test('a dead device must not keep writing history', () async {
    const spec = ModbusRegisterSpec(
      key: 'weight',
      registerType: ModbusElementType.holdingRegister,
      address: 0,
      dataType: ModbusDataType.uint16,
      pollGroup: 'fast',
    );

    final device = DyingModbusClient();
    final wrapper = ModbusClientWrapper('h', 502, 1,
        clientFactory: (h, p, u) => device);
    addTearDown(wrapper.dispose);
    wrapper.addPollGroup('fast', const Duration(milliseconds: 50));

    final adapter = ModbusDeviceClientAdapter(wrapper,
        specs: const {'weight': spec}, serverAlias: 'plc');
    addTearDown(adapter.dispose);

    final db = RecordingDatabase();
    final stateMan = await OpcUaStateMan.create(
      config: StateManConfig(opcua: []),
      keyMappings: KeyMappings(nodes: {}),
    );
    addTearDown(
        () => stateMan.close().timeout(const Duration(seconds: 5), onTimeout: () {}));
    final collector = Collector(
      config: CollectorConfig(collect: true),
      stateMan: stateMan,
      database: db,
    );
    addTearDown(collector.close);

    // The production subscribe path, unmodified.
    final Stream<DynamicValue> stream = adapter.subscribe('weight');
    await collector.collectEntryImpl(
        CollectEntry(key: 'weight', name: 'weight'), stream,
        skipFirstSample: false);

    wrapper.connect();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final whileAlive = db.rows.length;
    expect(whileAlive, greaterThan(0), reason: 'sanity: live polling writes');

    // The device stops answering. Every poll from here on times out.
    device.dead = true;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final afterDeath = db.rows.length - whileAlive;

    expect(afterDeath, 0,
        reason: '_onPollTick runs its publish loop unconditionally after the '
            'batch loop, whether or not the read succeeded, so every failed '
            'poll re-emits `sub.element.value` — the last good reading. '
            'ModbusDeviceClientAdapter.subscribe is a bare `.map()` over that '
            'stream, so the collector inserts each repeat. A dead device '
            'therefore writes a flat line of its last value into the '
            'timeseries at the poll rate instead of leaving a gap: $afterDeath '
            'fabricated rows in 500ms, all reading '
            '${db.rows.isEmpty ? "n/a" : db.rows.last}. Nothing downstream '
            'can distinguish that from a genuinely steady process value.');
  });
}
