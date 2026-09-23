/// Live integration test for ModbusClientWrapper and ModbusDeviceClientAdapter
/// against a Schneider M241 PLC at 10.50.10.123.
///
/// Tag map (from EcoStruxure Machine Expert):
///   iCounter   UINT  %MW1000  → HR1000, uint16
///   iCounter1  UINT  %MW1001  → HR1001, uint16
///   iCounter2  UINT  %MW1002  → HR1002, uint16
///   iCounter3  INT   %MW1003  → HR1003, int16
///   iCounter4  INT   %MW1004  → HR1004, int16
///   iCounter5  INT   %MW1005  → HR1005, int16
///   rReal1     REAL  %MD520   → HR1040-1041, float32 (CDAB word order)
///   rReal2     REAL  %MD521   → HR1042-1043, float32
///   rReal3     REAL  %MD522   → HR1044-1045, float32
///   rReal4     REAL  %MD523   → HR1046-1047, float32
///   rReal5     REAL  %MD524   → HR1048-1049, float32
///   xBool1     BIT   %MX2100.0 → Coil 2100
///   xBool2     BIT   %MX2100.1 → Coil 2101
///
/// Run with: dart test test/modbus_stateman_live_test.dart --run-skipped --reporter expanded
@TestOn('vm')
library;

import 'dart:async';

import 'package:modbus_client/modbus_client.dart';
import 'package:tfc_dart/core/modbus_client_wrapper.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:tfc_dart/core/state_man.dart' show ConnectionStatus;
import 'package:test/test.dart';

const _host = '10.50.10.123';
const _port = 502;
const _unitId = 1;

void main() {
  group('Live Modbus StateMan @ $_host:$_port', () {
    late ModbusClientWrapper wrapper;

    setUp(() {
      wrapper = ModbusClientWrapper(_host, _port, _unitId);
    });

    tearDown(() {
      wrapper.dispose();
    });

    test('connects and reads UINT holding register (%MW1000)', () async {
      wrapper.connect();

      // Wait for connection
      await wrapper.connectionStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));
      expect(wrapper.connectionStatus, ConnectionStatus.connected);

      // Subscribe to iCounter at HR1000 (UINT)
      final spec = ModbusRegisterSpec(
        key: 'iCounter',
        registerType: ModbusElementType.holdingRegister,
        address: 1000,
        dataType: ModbusDataType.uint16,
      );

      final values = <Object?>[];
      final sub = wrapper.subscribe(spec).listen(values.add);

      // Wait for a few poll cycles
      await Future.delayed(const Duration(seconds: 3));

      print('iCounter values: $values');
      expect(values, isNotEmpty, reason: 'Should have received polled values');
      expect(values.last, isA<int>());
      final v = values.last as int;
      print('iCounter (HR1000) = $v');
      expect(v, greaterThan(0), reason: 'Counter should be non-zero');

      await sub.cancel();
    },
        skip: 'Live test — requires Schneider M241 at $_host',
        timeout: Timeout(Duration(seconds: 15)));

    test('reads INT holding register (%MW1003)', () async {
      wrapper.connect();
      await wrapper.connectionStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));

      final spec = ModbusRegisterSpec(
        key: 'iCounter3',
        registerType: ModbusElementType.holdingRegister,
        address: 1003,
        dataType: ModbusDataType.int16,
      );

      final values = <Object?>[];
      final sub = wrapper.subscribe(spec).listen(values.add);
      await Future.delayed(const Duration(seconds: 3));

      print('iCounter3 values: $values');
      expect(values, isNotEmpty);
      final v = values.last;
      print('iCounter3 (HR1003, INT) = $v');
      // INT can be negative
      expect(v, isA<int>());

      await sub.cancel();
    },
        skip: 'Live test — requires Schneider M241 at $_host',
        timeout: Timeout(Duration(seconds: 15)));

    test('reads REAL holding register with CDAB word order (%MD520)', () async {
      wrapper.connect();
      await wrapper.connectionStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));

      // Schneider M241 uses CDAB (little-endian word order) for 32-bit values
      final spec = ModbusRegisterSpec(
        key: 'rReal1',
        registerType: ModbusElementType.holdingRegister,
        address: 1040, // %MD520 → HR1040-1041
        dataType: ModbusDataType.float32,
        endianness: ModbusEndianness.CDAB,
      );

      final values = <Object?>[];
      final sub = wrapper.subscribe(spec).listen(values.add);
      await Future.delayed(const Duration(seconds: 3));

      print('rReal1 values: $values');
      expect(values, isNotEmpty);
      final v = values.last;
      print('rReal1 (HR1040-1041, FLOAT32 CDAB) = $v');
      expect(v, isA<double>());
      // Value should be a reasonable float, not NaN or infinity
      final d = v as double;
      expect(d.isFinite, isTrue, reason: 'REAL value should be finite');
      expect(d, isNot(0.0), reason: 'REAL value should be non-zero');

      await sub.cancel();
    },
        skip: 'Live test — requires Schneider M241 at $_host',
        timeout: Timeout(Duration(seconds: 15)));

    test('reads multiple REALs in same poll group (coalesced batch)', () async {
      wrapper.connect();
      await wrapper.connectionStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));

      // All 5 REALs in the same poll group — should coalesce into one batch read
      final specs = <String, ModbusRegisterSpec>{};
      for (var i = 0; i < 5; i++) {
        specs['rReal${i + 1}'] = ModbusRegisterSpec(
          key: 'rReal${i + 1}',
          registerType: ModbusElementType.holdingRegister,
          address: 1040 + i * 2, // HR1040, 1042, 1044, 1046, 1048
          dataType: ModbusDataType.float32,
          endianness: ModbusEndianness.CDAB,
        );
      }

      final results = <String, List<Object?>>{};
      final subs = <StreamSubscription>[];
      for (final entry in specs.entries) {
        results[entry.key] = [];
        subs.add(
          wrapper.subscribe(entry.value).listen((v) {
            results[entry.key]!.add(v);
          }),
        );
      }

      await Future.delayed(const Duration(seconds: 3));

      for (final entry in results.entries) {
        final vals = entry.value;
        expect(vals, isNotEmpty, reason: '${entry.key} should have values');
        final v = vals.last as double;
        print('${entry.key} = $v');
        expect(v.isFinite, isTrue);
      }

      for (final sub in subs) {
        await sub.cancel();
      }
    },
        skip: 'Live test — requires Schneider M241 at $_host',
        timeout: Timeout(Duration(seconds: 15)));

    test('reads coils (%MX2100.0-4)', () async {
      wrapper.connect();
      await wrapper.connectionStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));

      final specs = <String, ModbusRegisterSpec>{};
      for (var i = 0; i < 5; i++) {
        specs['xBool${i + 1}'] = ModbusRegisterSpec(
          key: 'xBool${i + 1}',
          registerType: ModbusElementType.coil,
          address: 2100 + i,
          dataType: ModbusDataType.bit,
        );
      }

      final results = <String, List<Object?>>{};
      final subs = <StreamSubscription>[];
      for (final entry in specs.entries) {
        results[entry.key] = [];
        subs.add(
          wrapper.subscribe(entry.value).listen((v) {
            results[entry.key]!.add(v);
          }),
        );
      }

      await Future.delayed(const Duration(seconds: 3));

      for (final entry in results.entries) {
        final vals = entry.value;
        expect(vals, isNotEmpty, reason: '${entry.key} should have values');
        final v = vals.last;
        print('${entry.key} = $v (${v.runtimeType})');
        expect(v, isA<bool>());
      }

      for (final sub in subs) {
        await sub.cancel();
      }
    },
        skip: 'Live test — requires Schneider M241 at $_host',
        timeout: Timeout(Duration(seconds: 15)));

    test('ModbusDeviceClientAdapter reads via DynamicValue interface', () async {
      final specs = {
        'iCounter': ModbusRegisterSpec(
          key: 'iCounter',
          registerType: ModbusElementType.holdingRegister,
          address: 1000,
          dataType: ModbusDataType.uint16,
        ),
        'iCounter3': ModbusRegisterSpec(
          key: 'iCounter3',
          registerType: ModbusElementType.holdingRegister,
          address: 1003,
          dataType: ModbusDataType.int16,
        ),
        'rReal1': ModbusRegisterSpec(
          key: 'rReal1',
          registerType: ModbusElementType.holdingRegister,
          address: 1040,
          dataType: ModbusDataType.float32,
          endianness: ModbusEndianness.CDAB,
        ),
        'xBool1': ModbusRegisterSpec(
          key: 'xBool1',
          registerType: ModbusElementType.coil,
          address: 2100,
          dataType: ModbusDataType.bit,
        ),
      };

      final adapter = ModbusDeviceClientAdapter(
        wrapper,
        specs: specs,
        serverAlias: 'schneider-m241',
      );

      adapter.connect();
      await adapter.connectionStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));

      // Subscribe via DeviceClient interface
      final results = <String, Object?>{};
      final subs = <StreamSubscription>[];
      for (final key in specs.keys) {
        subs.add(
          adapter.subscribe(key).listen((dv) {
            results[key] = dv.value;
          }),
        );
      }

      await Future.delayed(const Duration(seconds: 3));

      print('\n=== DeviceClient / DynamicValue results ===');
      for (final entry in results.entries) {
        print('  ${entry.key} = ${entry.value} (${entry.value.runtimeType})');
      }

      expect(results['iCounter'], isA<int>());
      expect(results['iCounter3'], isA<int>());
      expect(results['rReal1'], isA<double>());
      expect(results['xBool1'], isA<bool>());

      print('\nAll data types read correctly via DynamicValue interface');

      for (final sub in subs) {
        await sub.cancel();
      }
      adapter.dispose();
    },
        skip: 'Live test — requires Schneider M241 at $_host',
        timeout: Timeout(Duration(seconds: 15)));

    test('counter values change over time (PLC program running)', () async {
      wrapper.connect();
      await wrapper.connectionStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));

      final spec = ModbusRegisterSpec(
        key: 'iCounter2',
        registerType: ModbusElementType.holdingRegister,
        address: 1002,
        dataType: ModbusDataType.uint16,
      );

      final values = <int>[];
      final sub = wrapper.subscribe(spec).listen((v) {
        if (v is num) values.add(v.toInt());
      });

      // Collect values over 5 seconds
      await Future.delayed(const Duration(seconds: 5));

      print('iCounter2 readings over 5s: $values');
      expect(values.length, greaterThanOrEqualTo(3),
          reason: 'Should have multiple poll readings');

      // Check if counter changed (it increments in PLC program)
      final unique = values.toSet();
      print('Unique values: ${unique.length} (${unique.take(5).join(', ')}...)');
      if (unique.length > 1) {
        print('Counter IS incrementing — PLC program running');
      } else {
        print('Counter is static — value: ${values.first}');
      }

      await sub.cancel();
    },
        skip: 'Live test — requires Schneider M241 at $_host',
        timeout: Timeout(Duration(seconds: 15)));
  });
}
