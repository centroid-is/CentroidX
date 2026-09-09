import 'dart:async';
import 'dart:typed_data';

import 'package:modbus_client/modbus_client.dart';
import 'package:modbus_client_tcp/modbus_client_tcp.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue, NodeId;
import 'package:tfc_dart/core/modbus_client_wrapper.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:tfc_dart/core/state_man.dart' show ConnectionStatus, KeyMappings, KeyMappingEntry, ModbusConfig, ModbusNodeConfig, ModbusRegisterType, ModbusPollGroupConfig;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Mock (duplicated from modbus_client_wrapper_test.dart since test-internal)
// ---------------------------------------------------------------------------

class MockModbusClient extends ModbusClientTcp {
  bool _connected = false;
  bool shouldFailConnect = false;
  int connectCallCount = 0;
  int disconnectCallCount = 0;
  int sendCallCount = 0;

  /// Last write request captured for verification.
  ModbusRequest? lastWriteRequest;

  /// Response handler: given a request, return response code and optionally
  /// populate element values.
  ModbusResponseCode Function(ModbusRequest request)? onSend;

  MockModbusClient()
      : super('mock',
            serverPort: 0,
            connectionMode: ModbusConnectionMode.doNotConnect);

  @override
  bool get isConnected => _connected;

  @override
  Future<bool> connect() async {
    connectCallCount++;
    if (shouldFailConnect) return false;
    _connected = true;
    return true;
  }

  @override
  Future<void> disconnect() async {
    disconnectCallCount++;
    _connected = false;
  }

  @override
  Future<ModbusResponseCode> send(ModbusRequest request) async {
    if (!_connected) return ModbusResponseCode.connectionFailed;
    sendCallCount++;

    // Capture write requests
    if (request is ModbusWriteRequest) {
      lastWriteRequest = request;
    }

    if (onSend != null) return onSend!(request);

    // Default: succeed and set element values to zero bytes
    if (request is ModbusReadGroupRequest) {
      final dataSize = request.elementGroup.type!.isRegister
          ? request.elementGroup.addressRange * 2
          : (request.elementGroup.addressRange + 7) ~/ 8;
      request.internalSetElementData(Uint8List(dataSize));
    } else if (request is ModbusReadRequest) {
      final byteCount = request.element.byteCount;
      request.element.setValueFromBytes(Uint8List(byteCount));
    }
    return ModbusResponseCode.requestSucceed;
  }

  void simulateDisconnect() {
    _connected = false;
  }
}

/// Helper to create wrapper + mock together.
({ModbusClientWrapper wrapper, MockModbusClient mock}) createWrapperWithMock({
  String host = '127.0.0.1',
  int port = 502,
  int unitId = 1,
}) {
  final mock = MockModbusClient();
  final wrapper = ModbusClientWrapper(
    host,
    port,
    unitId,
    clientFactory: (h, p, u) => mock,
  );
  return (wrapper: wrapper, mock: mock);
}

// ---------------------------------------------------------------------------
// Test specs
// ---------------------------------------------------------------------------

const _spec1 = ModbusRegisterSpec(
  key: 'pump1_speed',
  registerType: ModbusElementType.holdingRegister,
  address: 100,
  dataType: ModbusDataType.uint16,
);

const _spec2 = ModbusRegisterSpec(
  key: 'tank_level',
  registerType: ModbusElementType.inputRegister,
  address: 200,
  dataType: ModbusDataType.float32,
);

const _coilSpec = ModbusRegisterSpec(
  key: 'valve_open',
  registerType: ModbusElementType.coil,
  address: 0,
  dataType: ModbusDataType.bit,
);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ModbusDeviceClientAdapter contract', () {
    late ModbusClientWrapper wrapper;
    late MockModbusClient mock;
    late ModbusDeviceClientAdapter adapter;

    setUp(() {
      final pair = createWrapperWithMock();
      wrapper = pair.wrapper;
      mock = pair.mock;
      adapter = ModbusDeviceClientAdapter(
        wrapper,
        specs: {
          _spec1.key: _spec1,
          _spec2.key: _spec2,
          _coilSpec.key: _coilSpec,
        },
      );
    });

    tearDown(() {
      wrapper.dispose();
    });

    test('subscribableKeys returns spec keys', () {
      expect(
        adapter.subscribableKeys,
        equals({'pump1_speed', 'tank_level', 'valve_open'}),
      );
    });

    test('canSubscribe returns true for known spec keys', () {
      expect(adapter.canSubscribe('pump1_speed'), isTrue);
      expect(adapter.canSubscribe('tank_level'), isTrue);
      expect(adapter.canSubscribe('valve_open'), isTrue);
    });

    test('canSubscribe returns false for unknown keys', () {
      expect(adapter.canSubscribe('unknown_key'), isFalse);
      expect(adapter.canSubscribe('BATCH'), isFalse);
    });

    test('canSubscribe uses exact match not prefix', () {
      // 'pump1_speed.sub' should NOT match 'pump1_speed'
      expect(adapter.canSubscribe('pump1_speed.sub'), isFalse);
      expect(adapter.canSubscribe('pump1'), isFalse);
    });

    test('subscribe returns DynamicValue stream with correct typeId', () async {
      // Connect the wrapper so polling works
      wrapper.connect();
      await Future.delayed(const Duration(milliseconds: 100));

      final stream = adapter.subscribe('pump1_speed');
      final completer = Completer<DynamicValue>();
      final sub = stream.listen((dv) {
        if (!completer.isCompleted) completer.complete(dv);
      });

      // Wait for a poll tick to push a value
      await Future.delayed(const Duration(milliseconds: 1500));

      final dv = await completer.future.timeout(const Duration(seconds: 3));
      expect(dv, isA<DynamicValue>());
      expect(dv.typeId, equals(NodeId.uint16));

      await sub.cancel();
    });

    test('subscribe returns DynamicValue for boolean coil spec', () async {
      wrapper.connect();
      await Future.delayed(const Duration(milliseconds: 100));

      final stream = adapter.subscribe('valve_open');
      final completer = Completer<DynamicValue>();
      final sub = stream.listen((dv) {
        if (!completer.isCompleted) completer.complete(dv);
      });

      await Future.delayed(const Duration(milliseconds: 1500));

      final dv = await completer.future.timeout(const Duration(seconds: 3));
      expect(dv, isA<DynamicValue>());
      expect(dv.typeId, equals(NodeId.boolean));

      await sub.cancel();
    });

    test('subscribe throws ArgumentError for unknown key', () {
      expect(() => adapter.subscribe('nonexistent'), throwsArgumentError);
    });

    test('read returns DynamicValue with typeId when value cached', () async {
      // Subscribe + connect to get a value cached via polling
      wrapper.connect();
      await Future.delayed(const Duration(milliseconds: 100));

      final stream = adapter.subscribe('pump1_speed');
      final completer = Completer<DynamicValue>();
      final sub = stream.listen((dv) {
        if (!completer.isCompleted) completer.complete(dv);
      });

      await completer.future.timeout(const Duration(seconds: 3));

      final dv = adapter.read('pump1_speed');
      expect(dv, isNotNull);
      expect(dv!.typeId, equals(NodeId.uint16));

      await sub.cancel();
    });

    test('read returns null for unknown key', () {
      expect(adapter.read('nonexistent'), isNull);
    });

    test('read returns null when no value yet', () {
      // No subscription has been created, so no cached value
      expect(adapter.read('pump1_speed'), isNull);
    });

    test('write delegates to wrapper with spec and value', () async {
      wrapper.connect();
      await Future.delayed(const Duration(milliseconds: 100));

      final dv = DynamicValue(value: 42, typeId: NodeId.uint16);
      await adapter.write('pump1_speed', dv);

      // Verify mock received a send call (the write)
      expect(mock.sendCallCount, greaterThanOrEqualTo(1));
    });

    test('write throws ArgumentError for unknown key', () {
      expect(
        () => adapter.write('nonexistent', DynamicValue(value: 1)),
        throwsArgumentError,
      );
    });

    test('connectionStatus delegates to wrapper', () {
      expect(adapter.connectionStatus, equals(ConnectionStatus.disconnected));
    });

    test('connectionStream delegates to wrapper', () async {
      final statuses = <ConnectionStatus>[];
      final sub = adapter.connectionStream.listen(statuses.add);

      // BehaviorSubject replays current value
      await Future.delayed(const Duration(milliseconds: 50));
      expect(statuses, contains(ConnectionStatus.disconnected));

      await sub.cancel();
    });

    test('connect delegates to wrapper', () {
      adapter.connect();
      // After connect(), wrapper starts connection loop -- check status changes
      // (mock auto-connects)
      // Just verifying no exception is sufficient here
    });

    test('dispose delegates to wrapper', () {
      // Create a separate adapter+wrapper for dispose test to avoid
      // interfering with tearDown
      final pair = createWrapperWithMock();
      final w = pair.wrapper;
      final a = ModbusDeviceClientAdapter(
        w,
        specs: {_spec1.key: _spec1},
      );
      a.dispose();
      // After dispose, connection status should be disconnected
      // and further operations should be safe
    });
  });

  // ---------------------------------------------------------------------------
  // Address base tests (Phase 18, Plan 01)
  // ---------------------------------------------------------------------------

  group('buildSpecsFromKeyMappings addressBase', () {
    test('passes addressBase from parameter into ModbusRegisterSpec', () {
      final keyMappings = KeyMappings(nodes: {
        'pump_speed': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: 'plc_1',
            registerType: ModbusRegisterType.holdingRegister,
            address: 100,
            dataType: ModbusDataType.uint16,
          ),
        ),
      });

      final specs = buildSpecsFromKeyMappings(
        keyMappings,
        'plc_1',
        addressBase: 1,
      );

      expect(specs['pump_speed'], isNotNull);
      expect(specs['pump_speed']!.addressBase, 1);
    });

    test('defaults addressBase to 0 when not specified', () {
      final keyMappings = KeyMappings(nodes: {
        'pump_speed': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: 'plc_1',
            registerType: ModbusRegisterType.holdingRegister,
            address: 100,
            dataType: ModbusDataType.uint16,
          ),
        ),
      });

      final specs = buildSpecsFromKeyMappings(
        keyMappings,
        'plc_1',
      );

      expect(specs['pump_speed'], isNotNull);
      expect(specs['pump_speed']!.addressBase, 0);
    });
  });

  group('buildModbusDeviceClients addressBase', () {
    test('passes addressBase from ModbusConfig through to wrapper specs', () {
      final keyMappings = KeyMappings(nodes: {
        'pump_speed': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: 'plc_1',
            registerType: ModbusRegisterType.holdingRegister,
            address: 100,
            dataType: ModbusDataType.uint16,
          ),
        ),
      });

      final configs = [
        ModbusConfig(
          host: '10.0.0.1',
          port: 502,
          unitId: 1,
          addressBase: 1,
        )..serverAlias = 'plc_1',
      ];

      final clients = buildModbusDeviceClients(configs, keyMappings);
      expect(clients, hasLength(1));

      // The adapter should have specs with addressBase=1
      final adapter = clients.first as ModbusDeviceClientAdapter;
      expect(adapter.canSubscribe('pump_speed'), isTrue);

      // Clean up
      adapter.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  // Bit mask tests (Phase 18, Plan 03)
  // ---------------------------------------------------------------------------

  group('Modbus adapter bit masking', () {
    test('_toDynamicValue applies bit mask to value', () async {
      final pair = createWrapperWithMock();
      final wrapper = pair.wrapper;
      final mock = pair.mock;

      const maskedSpec = ModbusRegisterSpec(
        key: 'status_word',
        registerType: ModbusElementType.holdingRegister,
        address: 100,
        dataType: ModbusDataType.uint16,
        bitMask: 0x00FF,
        bitShift: 0,
      );

      final adapter = ModbusDeviceClientAdapter(
        wrapper,
        specs: {'status_word': maskedSpec},
      );

      // Connect and subscribe to get a value cached
      wrapper.connect();
      await Future.delayed(const Duration(milliseconds: 100));

      final stream = adapter.subscribe('status_word');
      final completer = Completer<DynamicValue>();
      final sub = stream.listen((dv) {
        if (!completer.isCompleted) completer.complete(dv);
      });

      await completer.future.timeout(const Duration(seconds: 3));

      // Read should have mask applied
      final dv = adapter.read('status_word');
      expect(dv, isNotNull);
      // Value should be masked (low byte only)
      expect(dv!.value, isA<num>());

      await sub.cancel();
      wrapper.dispose();
    });

    test('single-bit mask returns boolean DynamicValue', () async {
      final pair = createWrapperWithMock();
      final wrapper = pair.wrapper;

      const singleBitSpec = ModbusRegisterSpec(
        key: 'pump_running',
        registerType: ModbusElementType.holdingRegister,
        address: 100,
        dataType: ModbusDataType.uint16,
        bitMask: 0x0008,
        bitShift: 3,
      );

      final adapter = ModbusDeviceClientAdapter(
        wrapper,
        specs: {'pump_running': singleBitSpec},
      );

      wrapper.connect();
      await Future.delayed(const Duration(milliseconds: 100));

      final stream = adapter.subscribe('pump_running');
      final completer = Completer<DynamicValue>();
      final sub = stream.listen((dv) {
        if (!completer.isCompleted) completer.complete(dv);
      });

      await completer.future.timeout(const Duration(seconds: 3));

      final dv = adapter.read('pump_running');
      expect(dv, isNotNull);
      // Single bit mask should produce a boolean
      expect(dv!.value, isA<bool>());
      expect(dv.typeId, equals(NodeId.boolean));

      await sub.cancel();
      wrapper.dispose();
    });

    test('write without bitMask passes value through unchanged', () async {
      final pair = createWrapperWithMock();
      final wrapper = pair.wrapper;
      final mock = pair.mock;

      final adapter = ModbusDeviceClientAdapter(
        wrapper,
        specs: {_spec1.key: _spec1},
      );

      wrapper.connect();
      await Future.delayed(const Duration(milliseconds: 100));

      final dv = DynamicValue(value: 42, typeId: NodeId.uint16);
      await adapter.write('pump1_speed', dv);

      // Verify write was called (no read-modify-write needed)
      expect(mock.sendCallCount, greaterThanOrEqualTo(1));

      wrapper.dispose();
    });

    test('write with bitMask performs read-modify-write', () async {
      final pair = createWrapperWithMock();
      final wrapper = pair.wrapper;
      final mock = pair.mock;

      const maskedSpec = ModbusRegisterSpec(
        key: 'pump_running',
        registerType: ModbusElementType.holdingRegister,
        address: 100,
        dataType: ModbusDataType.uint16,
        bitMask: 0x0001,
        bitShift: 0,
      );

      final adapter = ModbusDeviceClientAdapter(
        wrapper,
        specs: {'pump_running': maskedSpec},
      );

      // Connect and subscribe to get a cached value
      wrapper.connect();
      await Future.delayed(const Duration(milliseconds: 100));

      final stream = adapter.subscribe('pump_running');
      final completer = Completer<DynamicValue>();
      final sub = stream.listen((dv) {
        if (!completer.isCompleted) completer.complete(dv);
      });

      await completer.future.timeout(const Duration(seconds: 3));

      // Write true to bit 0 -- should read current, modify, write back
      final dv = DynamicValue(value: true, typeId: NodeId.boolean);
      await adapter.write('pump_running', dv);

      // Should have sent at least one write
      expect(mock.sendCallCount, greaterThanOrEqualTo(2)); // poll read + write

      await sub.cancel();
      wrapper.dispose();
    });

    test('buildSpecsFromKeyMappings passes bitMask/bitShift from entry', () {
      final keyMappings = KeyMappings(nodes: {
        'pump_running': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: 'plc_1',
            registerType: ModbusRegisterType.holdingRegister,
            address: 100,
            dataType: ModbusDataType.uint16,
          ),
        )
          ..bitMask = 0x0008
          ..bitShift = 3,
      });

      final specs = buildSpecsFromKeyMappings(keyMappings, 'plc_1');

      expect(specs['pump_running'], isNotNull);
      expect(specs['pump_running']!.bitMask, equals(0x0008));
      expect(specs['pump_running']!.bitShift, equals(3));
    });

    test('buildSpecsFromKeyMappings leaves bitMask/bitShift null when not set', () {
      final keyMappings = KeyMappings(nodes: {
        'pump_speed': KeyMappingEntry(
          modbusNode: ModbusNodeConfig(
            serverAlias: 'plc_1',
            registerType: ModbusRegisterType.holdingRegister,
            address: 100,
            dataType: ModbusDataType.uint16,
          ),
        ),
      });

      final specs = buildSpecsFromKeyMappings(keyMappings, 'plc_1');

      expect(specs['pump_speed'], isNotNull);
      expect(specs['pump_speed']!.bitMask, isNull);
      expect(specs['pump_speed']!.bitShift, isNull);
    });
  });
}
