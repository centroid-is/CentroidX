/// The non-OPC-UA drivers supply their own source timestamp, so an alarm row
/// stops labelling a backend arrival instant as plant time.
///
/// **The defect these arms close.** Every protocol enters the pipe through
/// `PipeWorkerEndpoint._onSample` -> [translateOpcUaSample], which substitutes
/// its own `arrivedAt` when the sample carries no `sourceTimestamp` and calls
/// `onSourceTimeFallback`. Neither the Modbus driver nor the M2400 weighers
/// ever set one, so for the entire non-OPC-UA fleet the substitution fired on
/// every value and `alarm_history.ts_source` said `'plant'` over what was
/// really a backend receipt — exactly the lie `AlarmTsSource.backendReceipt`
/// exists to prevent (D-2).
///
/// Jón's ruling on MORNING-NOTES item 0, 2026-09-07, was option (b): the device
/// clients stamp, because the driver has the best estimate the protocol admits.
///
/// `onSourceTimeFallback` is the existing observable, so it is what these arms
/// watch. **Four of them are negative arms** ("the counter did NOT move"), and a
/// negative arm that cannot fail proves nothing — so the last group is the
/// control: a genuinely unstamped OPC UA sample must still move the counter and
/// still take `arrivedAt`. If the control ever goes green-by-collapse, the
/// negative arms above it are worthless.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:jbtm/src/m2400.dart';
import 'package:jbtm/src/m2400_dynamic_value.dart';
import 'package:jbtm/src/m2400_field_parser.dart';
import 'package:jbtm/src/m2400_fields.dart';
import 'package:modbus_client/modbus_client.dart';
import 'package:modbus_client_tcp/modbus_client_tcp.dart';
import 'package:open62541/open62541.dart' show DynamicValue, NodeId;
import 'package:tfc_dart/core/modbus_client_wrapper.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:tfc_dart/core/opcua_value_translation.dart';
import 'package:tfc_dart/core/state_man.dart' show StateMan;
import 'package:tfc_dart/core/umas_types.dart' show TypedVariableValue;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// A clock that only moves when the wire does
// ---------------------------------------------------------------------------

/// Epoch for the fake clock. Everything below is `_t0 + n seconds`.
final _t0 = DateTime.utc(2026, 9, 7, 6, 0, 0);

DateTime _t(int seconds) => _t0.add(Duration(seconds: seconds));

/// An arrival instant deliberately nowhere near any read instant, so a stamp
/// that fell back to it cannot be mistaken for one that did not.
final _arrivedAt = DateTime.utc(2031, 1, 1, 0, 0, 0);

/// A clock that advances ONE second per completed Modbus round trip and at no
/// other time.
///
/// This is what makes the arms below say something. A clock read at any moment
/// other than "just after the read returned" reads a different second, so
/// asserting an exact instant pins the *stamping site*, not merely the presence
/// of a stamp.
class WireClock {
  int ticks = 0;
  DateTime now() => _t(ticks);
  void roundTripCompleted() => ticks++;
}

// ---------------------------------------------------------------------------
// Mock Modbus client (shape borrowed from modbus_device_client_test.dart)
// ---------------------------------------------------------------------------

class MockModbusClient extends ModbusClientTcp {
  MockModbusClient(this._clock)
      : super('mock',
            serverPort: 0,
            connectionMode: ModbusConnectionMode.doNotConnect);

  final WireClock _clock;
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
  Future<ModbusResponseCode> send(ModbusRequest request) async {
    if (!_connected) return ModbusResponseCode.connectionFailed;
    if (request is ModbusReadGroupRequest) {
      final dataSize = request.elementGroup.type!.isRegister
          ? request.elementGroup.addressRange * 2
          : (request.elementGroup.addressRange + 7) ~/ 8;
      final data = Uint8List(dataSize);
      // A non-zero payload so the bit-mask arm has a bit to find.
      if (data.isNotEmpty) data[data.length - 1] = 0x06;
      request.internalSetElementData(data);
    } else if (request is ModbusReadRequest) {
      request.element.setValueFromBytes(Uint8List(request.element.byteCount));
    }
    // The wire answered. This is the instant the driver is entitled to claim.
    _clock.roundTripCompleted();
    return ModbusResponseCode.requestSucceed;
  }
}

const _plainSpec = ModbusRegisterSpec(
  key: 'pump1_speed',
  registerType: ModbusElementType.holdingRegister,
  address: 100,
  dataType: ModbusDataType.uint16,
);

const _maskedSpec = ModbusRegisterSpec(
  key: 'pump1_fault',
  registerType: ModbusElementType.holdingRegister,
  address: 100,
  dataType: ModbusDataType.uint16,
  bitMask: 0x0002,
  bitShift: 1,
);

/// Builds a connected wrapper + adapter driven by [clock].
({ModbusClientWrapper wrapper, ModbusDeviceClientAdapter adapter})
    _connectedAdapter(WireClock clock,
        {required Map<String, ModbusRegisterSpec> specs}) {
  final wrapper = ModbusClientWrapper(
    '127.0.0.1',
    502,
    1,
    clientFactory: (h, p, u) => MockModbusClient(clock),
    clock: clock.now,
  );
  final adapter = ModbusDeviceClientAdapter(
    wrapper,
    specs: specs,
    clock: clock.now,
  );
  return (wrapper: wrapper, adapter: adapter);
}

/// The first value the adapter publishes for [key], with the poll running.
Future<DynamicValue> _firstSample(
  ModbusClientWrapper wrapper,
  ModbusDeviceClientAdapter adapter,
  String key,
) async {
  wrapper.connect();
  await Future<void>.delayed(const Duration(milliseconds: 50));
  final completer = Completer<DynamicValue>();
  final sub = adapter.subscribe(key).listen((dv) {
    if (!completer.isCompleted) completer.complete(dv);
  });
  final dv = await completer.future.timeout(const Duration(seconds: 5));
  await sub.cancel();
  return dv;
}

/// Runs a sample through the pipe's translation edge and reports whether the
/// substitution fired.
({int substitutions, DateTime? sourceTime}) _translate(DynamicValue dv) {
  var fallbacks = 0;
  final translated = translateOpcUaSample(
    dv,
    arrivedAt: _arrivedAt,
    onSourceTimeFallback: () => fallbacks++,
  );
  return (substitutions: fallbacks, sourceTime: translated.sourceTime);
}

void main() {
  group('Modbus: the driver read instant is the source timestamp', () {
    test('a subscribed sample is stamped with the instant the READ completed',
        () async {
      final clock = WireClock();
      final pair = _connectedAdapter(clock, specs: {_plainSpec.key: _plainSpec});
      addTearDown(pair.wrapper.dispose);

      final dv = await _firstSample(pair.wrapper, pair.adapter, _plainSpec.key);

      // The clock stood at _t(0) before the round trip and _t(1) after it.
      // Stamping at subscribe time, or at construction, or at any point before
      // the wire answered, would read _t(0).
      expect(dv.sourceTimestamp, _t(1));
    });

    test('translateOpcUaSample does NOT substitute for a Modbus sample',
        () async {
      final clock = WireClock();
      final pair = _connectedAdapter(clock, specs: {_plainSpec.key: _plainSpec});
      addTearDown(pair.wrapper.dispose);

      final dv = await _firstSample(pair.wrapper, pair.adapter, _plainSpec.key);
      final result = _translate(dv);

      expect(result.substitutions, 0);
      expect(result.sourceTime, _t(1));
      // Belt and braces: the arrival instant is decades away, so a stamp that
      // fell back cannot pass this by coincidence.
      expect(result.sourceTime, isNot(_arrivedAt));
    });

    test('a BIT-MASKED sample keeps its read instant across the mask',
        () async {
      // applyBitMask constructs a fresh DynamicValue for a masked read. A stamp
      // applied before the mask is silently discarded there, and the masked
      // keys are exactly the digital status bits alarms are written from.
      final clock = WireClock();
      final pair =
          _connectedAdapter(clock, specs: {_maskedSpec.key: _maskedSpec});
      addTearDown(pair.wrapper.dispose);

      final dv = await _firstSample(pair.wrapper, pair.adapter, _maskedSpec.key);
      final result = _translate(dv);

      expect(dv.typeId, NodeId.boolean, reason: 'the mask did run');
      expect(dv.sourceTimestamp, _t(1));
      expect(result.substitutions, 0);
      expect(result.sourceTime, _t(1));
    });

    test('the cached one-shot read carries the instant of the read that '
        'produced it', () async {
      final clock = WireClock();
      final pair = _connectedAdapter(clock, specs: {_plainSpec.key: _plainSpec});
      addTearDown(pair.wrapper.dispose);

      await _firstSample(pair.wrapper, pair.adapter, _plainSpec.key);
      final ticksAtRead = clock.ticks;

      // Move the clock on WITHOUT a read for this key, the way wall time moves
      // between one poll and the next. Without this step the arm cannot tell a
      // cached instant from a freshly-read one -- they would be the same
      // second -- and a `read()` that re-stamped with `_clock()` would pass.
      clock.roundTripCompleted();
      expect(clock.now(), isNot(_t(ticksAtRead)), reason: 'the clock moved');

      final dv = pair.adapter.read(_plainSpec.key);
      expect(dv, isNotNull);
      // Not "now": the cached reading is as old as the round trip that fetched
      // it, and saying otherwise would be the same lie one layer down.
      expect(dv!.sourceTimestamp, _t(ticksAtRead));
      expect(_translate(dv).substitutions, 0);
    });
  });

  group('Modbus: UMAS-by-name values are stamped too', () {
    test('a scalar read is stamped with the instant handed to the converter',
        () {
      final dv = ModbusDeviceClientAdapter.typedVariableToDynamicValue(
        TypedVariableValue(
            typeName: 'INT', value: 42, rawBytes: Uint8List(2)),
        _t(7),
      );

      expect(dv.sourceTimestamp, _t(7));
      expect(dv.value, 42);
      expect(_translate(dv).substitutions, 0);
    });

    test('an FB struct stamps the parent and every member with ONE instant',
        () {
      // A struct is one read. Its members must not each invent an instant, and
      // none of them may be left null -- the pipe reads the parent, the FB
      // widgets read the members.
      final dv = ModbusDeviceClientAdapter.fbMembersToDynamicValue(
        {
          'p_Stat_xRunningFwd': TypedVariableValue(
              typeName: 'BOOL', value: true, rawBytes: Uint8List(1)),
          'HMI.p_Stat_rSpeed': TypedVariableValue(
              typeName: 'REAL', value: 1.5, rawBytes: Uint8List(4)),
        },
        _t(9),
      );

      expect(dv.sourceTimestamp, _t(9));
      expect(dv['p_Stat_xRunningFwd'].sourceTimestamp, _t(9));
      expect(dv['HMI.p_Stat_rSpeed'].sourceTimestamp, _t(9));
      expect(_translate(dv).substitutions, 0);
    });
  });

  group('M2400: the weigher value reaches the pipe stamped', () {
    test('a record with a device timestamp does NOT trigger the substitution',
        () {
      final deviceClock = DateTime.utc(2026, 9, 7, 5, 55, 0);
      final dv = convertRecordToDynamicValue(M2400ParsedRecord(
        type: M2400RecordType.recBatch,
        typedFields: const {M2400Field.weight: 12.5},
        unknownFields: const {},
        rawFields: const {'1': '12.50'},
        receivedAt: DateTime.utc(2026, 9, 7, 5, 55, 2),
        deviceTimestamp: deviceClock,
      ));

      final result = _translate(dv);
      expect(result.substitutions, 0);
      expect(result.sourceTime, deviceClock);
      expect(result.sourceTime, isNot(_arrivedAt));
    });

    test('a dotted child value does NOT trigger the substitution either', () {
      // M2400ClientWrapper.subscribe('BATCH.weight') publishes the child.
      final deviceClock = DateTime.utc(2026, 9, 7, 5, 55, 0);
      final parent = convertRecordToDynamicValue(M2400ParsedRecord(
        type: M2400RecordType.recBatch,
        typedFields: const {M2400Field.weight: 12.5},
        unknownFields: const {},
        rawFields: const {'1': '12.50'},
        receivedAt: DateTime.utc(2026, 9, 7, 5, 55, 2),
        deviceTimestamp: deviceClock,
      ));

      final result = _translate(parent['weight']);
      expect(result.substitutions, 0);
      expect(result.sourceTime, deviceClock);
    });
  });

  group('applyBitMask carries the provenance across the mask', () {
    test('a masked value keeps statusCode and sourceTimestamp', () {
      final stamped = DynamicValue(value: 0x02, typeId: NodeId.uint16)
        ..statusCode = opcUaUncertainLastUsableValue
        ..sourceTimestamp = _t(3);

      final masked = StateMan.applyBitMask(stamped, 0x02, 1);

      expect(masked.value, true, reason: 'single-bit mask yields a bool');
      expect(masked.sourceTimestamp, _t(3));
      expect(masked.statusCode, opcUaUncertainLastUsableValue);
    });

    test('a multi-bit masked value keeps them too', () {
      final stamped = DynamicValue(value: 0x0C, typeId: NodeId.uint16)
        ..statusCode = opcUaStatusCodeGood
        ..sourceTimestamp = _t(4);

      final masked = StateMan.applyBitMask(stamped, 0x0C, 2);

      expect(masked.value, 3);
      expect(masked.sourceTimestamp, _t(4));
      expect(masked.statusCode, opcUaStatusCodeGood);
    });
  });

  group('CONTROL: the substitution path stays live', () {
    // Without this group the four "did NOT substitute" arms above are
    // unfalsifiable: deleting the fallback branch entirely would make them all
    // pass. This is the arm that dies if that happens.
    test('an unstamped OPC UA sample DOES substitute and DOES report it', () {
      final unstamped = DynamicValue(value: 7)..statusCode = 0;

      final result = _translate(unstamped);

      expect(result.substitutions, 1);
      expect(result.sourceTime, _arrivedAt);
    });

    test('a stamped OPC UA sample keeps the server instant, as it always did',
        () {
      final serverInstant = DateTime.utc(2026, 9, 7, 5, 0, 0);
      final stamped = DynamicValue(value: 7)
        ..statusCode = 0
        ..sourceTimestamp = serverInstant;

      final result = _translate(stamped);

      expect(result.substitutions, 0);
      expect(result.sourceTime, serverInstant);
    });
  });
}
