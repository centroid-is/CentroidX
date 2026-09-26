/// Unit and E2E tests for ReadVariable (0x22) support.
///
/// Run: dart test test/umas_client_read_variable_test.dart
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:modbus_client_tcp/modbus_client_tcp.dart';
import 'package:tfc_dart/core/umas_client.dart';
import 'package:tfc_dart/core/umas_types.dart';
import 'package:test/test.dart';

void main() {
  group('dataSizeIndexFromByteSize', () {
    test('1 byte -> dataSizeIndex 1', () {
      expect(dataSizeIndexFromByteSize(1), 1);
    });

    test('2 bytes -> dataSizeIndex 2', () {
      expect(dataSizeIndexFromByteSize(2), 2);
    });

    test('4 bytes -> dataSizeIndex 3', () {
      expect(dataSizeIndexFromByteSize(4), 3);
    });

    test('8+ bytes -> dataSizeIndex 3 (clamped to 4-byte read per PLC4X)', () {
      expect(dataSizeIndexFromByteSize(8), 3);
    });

    test('256 bytes (STRING) -> dataSizeIndex 17', () {
      expect(dataSizeIndexFromByteSize(256), 17);
    });
  });

  group('UmasSubFunction.readVariable', () {
    test('has code 0x22', () {
      expect(UmasSubFunction.readVariable.code, 0x22);
    });
  });

  group('VariableReadRef', () {
    test('toBytes() for scalar REAL (block=1, baseOffset=0, offset=0)', () {
      final ref = VariableReadRef(
        blockNo: 1,
        baseOffset: 0,
        offset: 0,
        dataSizeIndex: 3, // REAL = 4 bytes
      );

      final bytes = ref.toBytes();

      // 7 bytes: dataSizeIndex(1) + block(2 LE) + 0x01(1) + baseOffset(2 LE) + offset(1)
      expect(bytes.length, 7);
      expect(bytes[0], 0x03); // isArray=0 | dataSizeIndex=3
      expect(bytes[1], 0x01); // block low byte
      expect(bytes[2], 0x00); // block high byte
      expect(bytes[3], 0x01); // constant 0x01
      expect(bytes[4], 0x00); // baseOffset low
      expect(bytes[5], 0x00); // baseOffset high
      expect(bytes[6], 0x00); // offset
    });

    test('toBytes() for INT (block=1, baseOffset=9, offset=0)', () {
      final ref = VariableReadRef(
        blockNo: 1,
        baseOffset: 9,
        offset: 0,
        dataSizeIndex: 2, // INT = 2 bytes
      );

      final bytes = ref.toBytes();
      expect(bytes.length, 7);
      expect(bytes[0], 0x02); // dataSizeIndex=2
      expect(bytes[1], 0x01); // block low
      expect(bytes[2], 0x00); // block high
      expect(bytes[3], 0x01); // constant
      expect(bytes[4], 0x09); // baseOffset low
      expect(bytes[5], 0x00); // baseOffset high
      expect(bytes[6], 0x00); // offset
    });

    test('toBytes() with isArray=true includes arrayLength (9 bytes)', () {
      final ref = VariableReadRef(
        blockNo: 2,
        baseOffset: 0,
        offset: 0,
        dataSizeIndex: 3,
        isArray: true,
        arrayLength: 10,
      );

      final bytes = ref.toBytes();
      expect(bytes.length, 9);
      expect(bytes[0], 0x13); // isArray=0x10 | dataSizeIndex=3
      // block = 2 LE
      expect(bytes[1], 0x02);
      expect(bytes[2], 0x00);
      expect(bytes[3], 0x01); // constant
      expect(bytes[4], 0x00); // baseOffset low
      expect(bytes[5], 0x00); // baseOffset high
      expect(bytes[6], 0x00); // offset
      // arrayLength = 10 LE
      expect(bytes[7], 0x0A); // 10 low
      expect(bytes[8], 0x00); // 10 high
    });

    test('fromVariable() computes dataSizeIndex from data type', () {
      final variable = UmasVariable(
        name: 'test',
        blockNo: 1,
        offset: 0,
        dataTypeId: 5,
      );
      final dataType = UmasDataTypeRef(
        id: 5,
        name: 'REAL',
        byteSize: 4,
      );

      final ref = VariableReadRef.fromVariable(variable, dataType);
      expect(ref.dataSizeIndex, 3); // 4 bytes -> index 3
      expect(ref.blockNo, 1);
      expect(ref.baseOffset, 0);
      expect(ref.offset, 0);
      expect(ref.isArray, false);
    });
  });

  group('ReadVariableResult', () {
    test('holds raw bytes', () {
      final result = ReadVariableResult(
        rawBytes: Uint8List.fromList([0x00, 0x00, 0xB4, 0x41]),
      );
      expect(result.rawBytes.length, 4);
    });
  });

  // ---------------------------------------------------------------------------
  // Typed response parsing tests (Plan 02 Task 1)
  // ---------------------------------------------------------------------------

  group('parseVariableValue', () {
    test('parses REAL (float32 LE) bytes to double', () {
      // 22.5 as float32 LE = 0x00 0x00 0xB4 0x41
      final bd = ByteData(4);
      bd.setFloat32(0, 22.5, Endian.little);
      final bytes = bd.buffer.asUint8List();
      final dataType = UmasDataTypes.builtIn[8]!; // REAL

      final result = parseVariableValue(bytes, 0, dataType);
      expect(result.value, closeTo(22.5, 0.001));
      expect(result.typeName, 'REAL');
      expect(result.rawBytes.length, 4);
    });

    test('parses INT (int16 LE) bytes to int', () {
      final bd = ByteData(2);
      bd.setInt16(0, 100, Endian.little);
      final bytes = bd.buffer.asUint8List();
      final dataType = UmasDataTypes.builtIn[4]!; // INT

      final result = parseVariableValue(bytes, 0, dataType);
      expect(result.value, 100);
      expect(result.typeName, 'INT');
    });

    test('parses BOOL true (0x01)', () {
      final bytes = Uint8List.fromList([0x01]);
      final dataType = UmasDataTypes.builtIn[1]!; // BOOL

      final result = parseVariableValue(bytes, 0, dataType);
      expect(result.value, true);
      expect(result.typeName, 'BOOL');
    });

    test('parses BOOL false (0x00)', () {
      final bytes = Uint8List.fromList([0x00]);
      final dataType = UmasDataTypes.builtIn[1]!; // BOOL

      final result = parseVariableValue(bytes, 0, dataType);
      expect(result.value, false);
      expect(result.typeName, 'BOOL');
    });

    test('parses UDINT (uint32 LE) bytes to int', () {
      final bd = ByteData(4);
      bd.setUint32(0, 12345, Endian.little);
      final bytes = bd.buffer.asUint8List();
      final dataType = UmasDataTypes.builtIn[7]!; // UDINT

      final result = parseVariableValue(bytes, 0, dataType);
      expect(result.value, 12345);
      expect(result.typeName, 'UDINT');
    });

    test('parses LREAL (float64 LE) bytes to double', () {
      final bd = ByteData(8);
      bd.setFloat64(0, 3.14, Endian.little);
      final bytes = bd.buffer.asUint8List();
      final dataType = UmasDataTypes.builtIn[12]!; // LREAL

      final result = parseVariableValue(bytes, 0, dataType);
      expect(result.value, closeTo(3.14, 0.0001));
      expect(result.typeName, 'LREAL');
    });

    test('parses UINT (uint16 LE) bytes to int', () {
      final bd = ByteData(2);
      bd.setUint16(0, 65535, Endian.little);
      final bytes = bd.buffer.asUint8List();
      final dataType = UmasDataTypes.builtIn[5]!; // UINT

      final result = parseVariableValue(bytes, 0, dataType);
      expect(result.value, 65535);
      expect(result.typeName, 'UINT');
    });

    test('parses DINT (int32 LE) bytes to int', () {
      final bd = ByteData(4);
      bd.setInt32(0, -42, Endian.little);
      final bytes = bd.buffer.asUint8List();
      final dataType = UmasDataTypes.builtIn[6]!; // DINT

      final result = parseVariableValue(bytes, 0, dataType);
      expect(result.value, -42);
      expect(result.typeName, 'DINT');
    });

    test('parses TIME (uint32 LE milliseconds) to int', () {
      final bd = ByteData(4);
      bd.setUint32(0, 3600000, Endian.little);
      final bytes = bd.buffer.asUint8List();
      final dataType = UmasDataTypes.builtIn[10]!; // TIME

      final result = parseVariableValue(bytes, 0, dataType);
      expect(result.value, 3600000);
      expect(result.typeName, 'TIME');
    });

    test('parses BYTE to int', () {
      final bytes = Uint8List.fromList([0xAB]);
      final dataType = UmasDataTypes.builtIn[21]!; // BYTE

      final result = parseVariableValue(bytes, 0, dataType);
      expect(result.value, 0xAB);
      expect(result.typeName, 'BYTE');
    });

    test('parses WORD (uint16 LE) to int', () {
      final bd = ByteData(2);
      bd.setUint16(0, 0xCAFE, Endian.little);
      final bytes = bd.buffer.asUint8List();
      final dataType = UmasDataTypes.builtIn[22]!; // WORD

      final result = parseVariableValue(bytes, 0, dataType);
      expect(result.value, 0xCAFE);
      expect(result.typeName, 'WORD');
    });

    test('parses DWORD (uint32 LE) to int', () {
      final bd = ByteData(4);
      bd.setUint32(0, 0xDEADBEEF, Endian.little);
      final bytes = bd.buffer.asUint8List();
      final dataType = UmasDataTypes.builtIn[23]!; // DWORD

      final result = parseVariableValue(bytes, 0, dataType);
      expect(result.value, 0xDEADBEEF);
      expect(result.typeName, 'DWORD');
    });

    test('parses LINT (int64 LE) to int', () {
      final bd = ByteData(8);
      bd.setInt64(0, -9876543210, Endian.little);
      final bytes = bd.buffer.asUint8List();
      final dataType = UmasDataTypes.builtIn[13]!; // LINT

      final result = parseVariableValue(bytes, 0, dataType);
      expect(result.value, -9876543210);
      expect(result.typeName, 'LINT');
    });

    test('parses ULINT (uint64 LE) to int', () {
      final bd = ByteData(8);
      bd.setUint64(0, 9876543210, Endian.little);
      final bytes = bd.buffer.asUint8List();
      final dataType = UmasDataTypes.builtIn[24]!; // ULINT

      final result = parseVariableValue(bytes, 0, dataType);
      expect(result.value, 9876543210);
      expect(result.typeName, 'ULINT');
    });

    test('parses STRING (null-terminated UTF-8)', () {
      // "Hello" + null + padding
      final bytes = Uint8List.fromList(
          [0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x00, 0x00, 0x00]);
      final dataType = UmasDataTypeRef(
        id: 7,
        name: 'STRING',
        byteSize: 8,
      );

      final result = parseVariableValue(bytes, 0, dataType);
      expect(result.value, 'Hello');
      expect(result.typeName, 'STRING');
    });

    test('throws on buffer underflow (T-05-04)', () {
      // Only 2 bytes but REAL needs 4
      final bytes = Uint8List.fromList([0x00, 0x00]);
      final dataType = UmasDataTypes.builtIn[8]!; // REAL

      expect(
        () => parseVariableValue(bytes, 0, dataType),
        throwsA(isA<UmasException>()),
      );
    });
  });

  group('parseVariableValues', () {
    test('parses concatenated REAL + INT bytes', () {
      // 22.5 as REAL (4 bytes) + 100 as INT (2 bytes) = 6 bytes
      final bd = ByteData(6);
      bd.setFloat32(0, 22.5, Endian.little);
      bd.setInt16(4, 100, Endian.little);
      final bytes = bd.buffer.asUint8List();

      final types = [
        UmasDataTypes.builtIn[8]!, // REAL
        UmasDataTypes.builtIn[4]!, // INT
      ];

      final results = parseVariableValues(bytes, types);
      expect(results.length, 2);
      expect(results[0].value, closeTo(22.5, 0.001));
      expect(results[0].typeName, 'REAL');
      expect(results[1].value, 100);
      expect(results[1].typeName, 'INT');
    });

    test('throws on total buffer underflow (T-05-05)', () {
      // Only 4 bytes but REAL + INT needs 6
      final bytes = Uint8List.fromList([0x00, 0x00, 0xB4, 0x41]);
      final types = [
        UmasDataTypes.builtIn[8]!, // REAL (4 bytes)
        UmasDataTypes.builtIn[4]!, // INT (2 bytes) -- would overflow
      ];

      expect(
        () => parseVariableValues(bytes, types),
        throwsA(isA<UmasException>()),
      );
    });

    test('rejects types list > 255 (T-05-05 cap)', () {
      final bytes = Uint8List(256 * 2); // enough bytes
      final types = List.generate(
        256,
        (_) => UmasDataTypes.builtIn[4]!, // 256 INT refs
      );

      expect(
        () => parseVariableValues(bytes, types),
        throwsA(isA<UmasException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // E2E tests against the Python stub server
  // ---------------------------------------------------------------------------

  group('readVariable() E2E', () {
    late int stubPort;
    Process? serverProcess;

    String findProjectRoot() {
      var dir = Directory.current;
      while (dir.path != dir.parent.path) {
        if (File('${dir.path}/test/umas_stub_server.py').existsSync()) {
          return dir.path;
        }
        dir = dir.parent;
      }
      return '${Directory.current.path}/../..';
    }

    final portPattern = RegExp(r'PORT=(\d+)');

    Future<void> startStub() async {
      final stubScript = '${findProjectRoot()}/test/umas_stub_server.py';
      String python;
      try {
        final r = await Process.run('python3', ['--version']);
        python = r.exitCode == 0 ? 'python3' : 'python';
      } catch (_) {
        python = 'python';
      }

      serverProcess = await Process.start(
        python,
        ['-u', stubScript, '--port', '0'],
      );

      serverProcess!.stderr
          .transform(const SystemEncoding().decoder)
          .listen((line) => stderr.write('[STUB ERR] $line'));

      final completer = Completer<int>();
      serverProcess!.stdout
          .transform(const SystemEncoding().decoder)
          .listen((line) {
        stdout.write('[STUB] $line');
        if (!completer.isCompleted) {
          final match = portPattern.firstMatch(line);
          if (match != null) {
            completer.complete(int.parse(match.group(1)!));
          }
        }
      });

      stubPort = await completer.future.timeout(const Duration(seconds: 5));
    }

    setUpAll(() async {
      await startStub();
    });

    tearDownAll(() {
      serverProcess?.kill();
      serverProcess = null;
    });

    late ModbusClientTcp tcp;

    setUp(() {
      tcp = ModbusClientTcp(
        '127.0.0.1',
        serverPort: stubPort,
        connectionTimeout: const Duration(seconds: 3),
      );
    });

    tearDown(() async {
      await tcp.disconnect();
    });

    test('reads single REAL variable (temperature = 22.5)', () async {
      await tcp.connect();
      final umas = UmasClient(sendFn: tcp.send);
      // Auto-init + get CRCs
      await umas.readPlcStatus();

      final ref = VariableReadRef(
        blockNo: 1,
        baseOffset: 0,
        offset: 0,
        dataSizeIndex: 3, // REAL = 4 bytes
      );

      final result = await umas.readVariable([ref]);

      expect(result.rawBytes.length, 4);
      final bd = ByteData.sublistView(result.rawBytes);
      final temperature = bd.getFloat32(0, Endian.little);
      expect(temperature, closeTo(22.5, 0.01));
    });

    test('reads two variables (temperature REAL + setpoint INT) = 6 bytes',
        () async {
      await tcp.connect();
      final umas = UmasClient(sendFn: tcp.send);
      await umas.readPlcStatus();

      final refs = [
        // temperature: block=1, baseOffset=0, REAL (4 bytes, index=3)
        VariableReadRef(
          blockNo: 1,
          baseOffset: 0,
          offset: 0,
          dataSizeIndex: 3,
        ),
        // setpoint: block=1, byte address 9 -> baseOffset=0 (page 0),
        // offset=9 (low byte), INT (2 bytes, index=2). Schneider paged
        // address: address = baseOffset*256 + offset.
        VariableReadRef(
          blockNo: 1,
          baseOffset: 0,
          offset: 9,
          dataSizeIndex: 2,
        ),
      ];

      final result = await umas.readVariable(refs);

      // 4 bytes (REAL) + 2 bytes (INT) = 6 bytes total
      expect(result.rawBytes.length, 6);

      final bd = ByteData.sublistView(result.rawBytes);
      final temperature = bd.getFloat32(0, Endian.little);
      expect(temperature, closeTo(22.5, 0.01));

      final setpoint = bd.getInt16(4, Endian.little);
      expect(setpoint, 100);
    });

    test('throws when blockCrcs is null (readPlcStatus not called)', () async {
      await tcp.connect();
      final umas = UmasClient(sendFn: tcp.send);
      // Do NOT call readPlcStatus -- blockCrcs will be null after init

      // Force session to paired state without calling readPlcStatus
      await umas.readPlcId();
      await umas.init();

      final ref = VariableReadRef(
        blockNo: 1,
        baseOffset: 0,
        offset: 0,
        dataSizeIndex: 3,
      );

      expect(
        () => umas.readVariable([ref]),
        throwsA(isA<UmasException>()),
      );
    });

    test('caps refs.length to 255 (T-05-02 DoS mitigation)', () async {
      await tcp.connect();
      final umas = UmasClient(sendFn: tcp.send);
      await umas.readPlcStatus();

      // Create 300 refs -- should be capped to 255
      final refs = List.generate(
        300,
        (_) => VariableReadRef(
          blockNo: 1,
          baseOffset: 0,
          offset: 0,
          dataSizeIndex: 3,
        ),
      );

      // Should not throw -- just cap silently
      final result = await umas.readVariable(refs);
      expect(result.rawBytes, isNotEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // readVariables() E2E tests (Plan 02 Task 2)
  // ---------------------------------------------------------------------------

  group('readVariables() E2E', () {
    late int stubPort;
    Process? serverProcess;

    String findProjectRoot() {
      var dir = Directory.current;
      while (dir.path != dir.parent.path) {
        if (File('${dir.path}/test/umas_stub_server.py').existsSync()) {
          return dir.path;
        }
        dir = dir.parent;
      }
      return '${Directory.current.path}/../..';
    }

    final portPattern = RegExp(r'PORT=(\d+)');

    Future<void> startStub() async {
      final stubScript = '${findProjectRoot()}/test/umas_stub_server.py';
      String python;
      try {
        final r = await Process.run('python3', ['--version']);
        python = r.exitCode == 0 ? 'python3' : 'python';
      } catch (_) {
        python = 'python';
      }

      serverProcess = await Process.start(
        python,
        ['-u', stubScript, '--port', '0'],
      );

      serverProcess!.stderr
          .transform(const SystemEncoding().decoder)
          .listen((line) => stderr.write('[STUB ERR] $line'));

      final completer = Completer<int>();
      serverProcess!.stdout
          .transform(const SystemEncoding().decoder)
          .listen((line) {
        stdout.write('[STUB] $line');
        if (!completer.isCompleted) {
          final match = portPattern.firstMatch(line);
          if (match != null) {
            completer.complete(int.parse(match.group(1)!));
          }
        }
      });

      stubPort = await completer.future.timeout(const Duration(seconds: 5));
    }

    setUpAll(() async {
      await startStub();
    });

    tearDownAll(() {
      serverProcess?.kill();
      serverProcess = null;
    });

    late ModbusClientTcp tcp;

    setUp(() {
      tcp = ModbusClientTcp(
        '127.0.0.1',
        serverPort: stubPort,
        connectionTimeout: const Duration(seconds: 3),
      );
    });

    tearDown(() async {
      await tcp.disconnect();
    });

    test('reads single REAL as typed value (temperature = 22.5)', () async {
      await tcp.connect();
      final umas = UmasClient(sendFn: tcp.send);
      await umas.readPlcStatus();

      final tempVar = UmasVariable(
        name: 'temperature',
        blockNo: 1,
        offset: 0,
        dataTypeId: 5,
      );
      final realType = UmasDataTypes.builtIn[8]!; // REAL

      final results = await umas.readVariables([(tempVar, realType)]);
      expect(results.length, 1);
      expect(results[0].value, closeTo(22.5, 0.01));
      expect(results[0].typeName, 'REAL');
      expect(results[0].value, isA<double>());
    });

    test('reads two typed values (temperature REAL + setpoint INT)', () async {
      await tcp.connect();
      final umas = UmasClient(sendFn: tcp.send);
      await umas.readPlcStatus();

      final tempVar = UmasVariable(
        name: 'temperature',
        blockNo: 1,
        offset: 0,
        dataTypeId: 5,
      );
      final setpointVar = UmasVariable(
        name: 'setpoint',
        blockNo: 1,
        offset: 9,
        dataTypeId: 1,
      );
      final realType = UmasDataTypes.builtIn[8]!; // REAL
      final intType = UmasDataTypes.builtIn[4]!; // INT

      final results = await umas.readVariables([
        (tempVar, realType),
        (setpointVar, intType),
      ]);
      expect(results.length, 2);
      expect(results[0].value, closeTo(22.5, 0.01));
      expect(results[0].typeName, 'REAL');
      expect(results[1].value, 100);
      expect(results[1].typeName, 'INT');
    });

    test('reads BOOL typed value (motor_running = true)', () async {
      await tcp.connect();
      final umas = UmasClient(sendFn: tcp.send);
      await umas.readPlcStatus();

      final motorVar = UmasVariable(
        name: 'motor_running',
        blockNo: 1,
        offset: 8,
        dataTypeId: 6,
      );
      final boolType = UmasDataTypes.builtIn[1]!; // BOOL

      final results = await umas.readVariables([(motorVar, boolType)]);
      expect(results.length, 1);
      expect(results[0].value, true);
      expect(results[0].typeName, 'BOOL');
      expect(results[0].value, isA<bool>());
    });

    test('VariableReadRef.fromVariable sets isArray for classIdentifier 4',
        () {
      final variable = UmasVariable(
        name: 'arr_test',
        blockNo: 2,
        offset: 0,
        dataTypeId: 100,
      );
      final arrayType = UmasDataTypeRef(
        id: 100,
        name: 'REAL',
        byteSize: 12, // 3 x 4 bytes (REAL element size)
        classIdentifier: 4, // array
        dataType: 8, // REAL element type id (PLC4X UmasDataType enum)
      );

      final ref = VariableReadRef.fromVariable(variable, arrayType);
      expect(ref.isArray, true);
      expect(ref.arrayLength, 3); // 12 / 4 = 3 elements
      expect(ref.toBytes().length, 9); // array ref is 9 bytes
    });

    test('VariableReadRef.fromVariable non-array has isArray=false', () {
      final variable = UmasVariable(
        name: 'scalar',
        blockNo: 1,
        offset: 0,
        dataTypeId: 5,
      );
      final scalarType = UmasDataTypes.builtIn[8]!; // REAL

      final ref = VariableReadRef.fromVariable(variable, scalarType);
      expect(ref.isArray, false);
      expect(ref.arrayLength, 0);
      expect(ref.toBytes().length, 7); // scalar ref is 7 bytes
    });

    // ------------------------------------------------------------------
    // Regression: DROP_HEALTH whole-array underflow (28 of 31 BOOL).
    //
    // The live M580 emits DD03 ARRAY records with `dataType == self-id`
    // (the array's own type id), NOT the element type id. For
    // `ARRAY[1..31] OF BOOL` that's `id=0x1F=31, dataType=0x1F=31`. The
    // encoder must NOT treat this as a 4-byte-per-element wide read --
    // doing so asks the PLC for 7x4 = 28 bytes, dropping the last 3
    // BOOLs. The fix decodes the element width from the resolved
    // `arrayElementByteSize` carried on the dataType (set by the tree
    // builder from the DD02 UmasArrayTypeDefinition) and falls back to
    // parsing the canonical Schneider type name when the legacy
    // self-referencing DD03 shape is the only thing available.
    // ------------------------------------------------------------------
    test(
        'fromVariable() for ARRAY[1..31] OF BOOL with DD03 self-referencing '
        'dataType encodes dsi=1, arrayLength=31 (DROP_HEALTH regression)',
        () {
      final variable = UmasVariable(
        name: 'DROP_HEALTH',
        blockNo: 0x33,
        offset: 0x90,
        dataTypeId: 0x1F,
      );
      // Exactly the shape DD03 emits on the live M580: dataType == id,
      // classIdentifier == 4, byteSize == total array bytes.
      const arrayType = UmasDataTypeRef(
        id: 0x1F,
        name: 'ARRAY[1..31] OF BOOL',
        byteSize: 31,
        classIdentifier: 4,
        dataType: 0x1F, // self-referencing -- the bug-shape
      );

      final ref = VariableReadRef.fromVariable(variable, arrayType);
      expect(ref.isArray, true);
      expect(ref.arrayLength, 31,
          reason: 'Must encode 31 BOOLs, not 7 (which is 31/4).');
      expect(ref.dataSizeIndex, 1,
          reason: 'BOOL is 1 byte, so dataSizeIndex must be 1 not 3.');
      // Wire-byte sanity: arrayLength field is bytes[7..8] (LE).
      final bytes = ref.toBytes();
      expect(bytes.length, 9);
      expect(bytes[0] & 0x10, 0x10, reason: 'isArray bit set');
      expect(bytes[0] & 0x0F, 0x01, reason: 'dataSizeIndex=1 in low nibble');
      expect(bytes[7], 0x1F); // 31 low byte
      expect(bytes[8], 0x00); // 31 high byte
    });

    test(
        'fromVariable() for ARRAY OF INT with DD03 self-referencing dataType '
        'recovers element width from the type name',
        () {
      final variable = UmasVariable(
        name: 'arr',
        blockNo: 1,
        offset: 0,
        dataTypeId: 0x42,
      );
      const arrayType = UmasDataTypeRef(
        id: 0x42,
        name: 'ARRAY[0..9] OF INT',
        byteSize: 20, // 10 x INT(2)
        classIdentifier: 4,
        dataType: 0x42, // self-referencing -- the bug-shape
      );

      final ref = VariableReadRef.fromVariable(variable, arrayType);
      expect(ref.isArray, true);
      expect(ref.arrayLength, 10,
          reason: '20 bytes / 2 bytes (INT) = 10 elements');
      expect(ref.dataSizeIndex, 2,
          reason: 'INT is 2 bytes, so dataSizeIndex must be 2.');
    });
  });
}
