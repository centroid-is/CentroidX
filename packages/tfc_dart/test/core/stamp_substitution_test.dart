/// A substituted instant must never reach an alarm row wearing `plant`.
///
/// **What the driver-stamp task measured, and why this reverses half of it.**
/// On 2026-09-07 the Modbus and M2400 drivers were made to stamp
/// `sourceTimestamp` themselves, so that `translateOpcUaSample` would stop
/// substituting its own arrival instant for the whole non-OPC-UA fleet. That
/// worked, and it produced an honest verdict: for Modbus, `'plant'` now meant
/// *the driver's read instant* — a clock on the backend host, one line after
/// the socket answered — and for an M2400 record with no device clock it meant
/// `receivedAt`, also a backend clock, indistinguishable from the honest branch
/// beside it. The defect went from a lie to an approximation still travelling
/// under a label that asserts otherwise.
///
/// **The field has a contract and it was being broken.** `package:open62541`
/// (`dynamic_value.dart:90-97`) says of `sourceTimestamp`: *"The instant the
/// SOURCE (the PLC, not this process) says the value was produced, or null when
/// the server sent no source timestamp. Null is deliberate and load-bearing: a
/// consumer that needs an instant must substitute its own arrival time
/// knowingly, and record that it did."* Modbus's `readAt` is this process.
/// M2400's `receivedAt` is this process. Neither belongs in the field, and
/// there is no room in a bare `DateTime` to say which clock it came from.
///
/// So the drivers stop offering a substitute, and the two `resolveAlarmStamp`
/// callers get the right answer by the mechanism D-2 already built: one unknown
/// poisons the bound set.
///
/// **There are two alarm paths and only one of them crosses the pipe.**
/// `alarm.dart:755` (`AlarmMan.onChange`, direct mode) reads `sourceTimestamp`
/// straight off the open62541 value with no pipe, no relay type and no isolate.
/// `alarm_rule_watcher.dart:332` reads `sourceTime` off the value the pipe
/// delivered to main. A fix that only rides the pipe leaves the first one
/// lying. This file pins the first; `stamp_substitution_flag_test.dart` pins
/// the second.
///
/// Every arm here uses instants **years** apart, so a stamp that took the wrong
/// clock cannot pass by coincidence, and every negative arm is paired with a
/// live control that must keep passing under any collapse that would make the
/// negative vacuously true.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:modbus_client/modbus_client.dart';
import 'package:modbus_client_tcp/modbus_client_tcp.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue, NodeId;
import 'package:tfc_dart/core/alarm_stamp.dart';
import 'package:tfc_dart/core/modbus_client_wrapper.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:tfc_dart/core/opcua_value_translation.dart';
import 'package:tfc_dart/core/state_man.dart' show StateMan;
import 'package:tfc_dart/core/umas_types.dart' show TypedVariableValue;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Instants, deliberately far apart
// ---------------------------------------------------------------------------

/// The driver's read instant / the weigher's parse instant: a backend clock.
final _driverClock = DateTime.utc(2026, 9, 7, 6, 0, 0);

/// A genuine PLC instant. Two years from [_driverClock] so no arm can confuse
/// them and no arm can pass because both happened to be "now".
final _plantClock = DateTime.utc(2028, 4, 1, 9, 30, 0);

/// The instant the alarm engine's injected clock reads. Different again.
final _evaluationClock = DateTime.utc(2030, 12, 24, 17, 45, 0);

/// The pipe's own arrival instant. Different again.
final _arrivedAt = DateTime.utc(2031, 1, 1, 0, 0, 0);

/// A clock that advances one second per completed Modbus round trip and at no
/// other time, so an arm asserting an exact instant pins the *stamping site*
/// rather than merely the presence of a stamp.
class WireClock {
  int ticks = 0;
  DateTime now() => _driverClock.add(Duration(seconds: ticks));
  void roundTripCompleted() => ticks++;
}

/// A clock that never moves by itself and counts every read, so an arm can
/// prove `resolveAlarmStamp` reached for it (or did not).
class CountingClock {
  CountingClock(this.at);
  final DateTime at;
  int reads = 0;
  DateTime call() {
    reads++;
    return at;
  }
}

// ---------------------------------------------------------------------------
// Mock Modbus client (shape borrowed from driver_source_timestamps_test.dart)
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
      if (data.isNotEmpty) data[data.length - 1] = 0x06;
      request.internalSetElementData(data);
    } else if (request is ModbusReadRequest) {
      request.element.setValueFromBytes(Uint8List(request.element.byteCount));
    }
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
  );
  return (wrapper: wrapper, adapter: adapter);
}

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

/// A value shaped like one an OPC UA server stamped: the control for every
/// negative arm below.
DynamicValue _serverStamped() =>
    DynamicValue(value: 42, typeId: NodeId.uint16)..sourceTimestamp = _plantClock;

void main() {
  // If these coincide, every arm below is vacuous: "not the driver clock"
  // proves nothing when the driver clock and the plant clock are one reading.
  test('the fixture instants are all distinct', () {
    final all = <DateTime>{
      _driverClock,
      _plantClock,
      _evaluationClock,
      _arrivedAt,
    };
    expect(all, hasLength(4));
  });

  group('Modbus: the driver offers no source timestamp at all', () {
    test('NEGATIVE: a subscribed sample carries none', () async {
      final clock = WireClock();
      final c = _connectedAdapter(clock, specs: {_plainSpec.key: _plainSpec});
      final dv = await _firstSample(c.wrapper, c.adapter, _plainSpec.key);
      c.adapter.dispose();

      // Modbus has no device instant. The driver's read instant is a clock on
      // this host and this field is documented as not being one.
      expect(dv.sourceTimestamp, isNull);
      // The read still happened — the arm is not passing because nothing ran.
      expect(clock.ticks, greaterThan(0));
    });

    test('NEGATIVE: a bit-masked sample carries none either', () async {
      // applyBitMask builds a fresh DynamicValue. It must not resurrect a
      // stamp, and it must not be the reason this arm passes.
      final clock = WireClock();
      final c = _connectedAdapter(clock, specs: {_maskedSpec.key: _maskedSpec});
      final dv = await _firstSample(c.wrapper, c.adapter, _maskedSpec.key);
      c.adapter.dispose();

      expect(dv.sourceTimestamp, isNull);
      expect(dv.asBool, isTrue, reason: 'the mask still produced its value');
    });

    test('NEGATIVE: the cached one-shot read carries none', () async {
      final clock = WireClock();
      final c = _connectedAdapter(clock, specs: {_plainSpec.key: _plainSpec});
      addTearDown(c.wrapper.dispose);

      await _firstSample(c.wrapper, c.adapter, _plainSpec.key);
      final atRead = clock.now();

      // Move the clock on WITHOUT a read for this key, the way wall time moves
      // between one poll and the next. Without this the arm cannot tell a
      // cached instant from a freshly-minted one — they would be the same
      // second — and a `read()` that re-stamped with `_clock()` would pass.
      clock.roundTripCompleted();
      expect(clock.now(), isNot(atRead), reason: 'the clock actually moved');

      final dv = c.adapter.read(_plainSpec.key);

      expect(dv, isNotNull, reason: 'the poll produced a cached value to read');
      expect(dv!.sourceTimestamp, isNull);
      // Neither the read instant nor "now": nothing at all.
      expect(dv.sourceTimestamp, isNot(atRead));
      expect(dv.sourceTimestamp, isNot(clock.now()));
    });

    test('NEGATIVE: a UMAS scalar carries none', () {
      final dv = ModbusDeviceClientAdapter.typedVariableToDynamicValue(
        TypedVariableValue(
            value: 7, typeName: 'INT', rawBytes: Uint8List(2)),
      );

      expect(dv.sourceTimestamp, isNull);
      expect(dv.asInt, 7, reason: 'the value still converted');
    });

    test('NEGATIVE: a UMAS FB struct carries none, parent or member', () {
      final dv = ModbusDeviceClientAdapter.fbMembersToDynamicValue(
        {
          'p_Stat_xRunningFwd': TypedVariableValue(
              value: true, typeName: 'BOOL', rawBytes: Uint8List(1)),
        },
      );

      expect(dv.sourceTimestamp, isNull);
      expect(dv['p_Stat_xRunningFwd'].sourceTimestamp, isNull);
      expect(dv['p_Stat_xRunningFwd'].asBool, isTrue,
          reason: 'the member still converted');
    });
  });

  group('CONTROL: a genuine OPC UA stamp is untouched by any of this', () {
    test('a server-stamped value keeps its instant', () {
      expect(_serverStamped().sourceTimestamp, _plantClock);
    });

    test('applyBitMask still carries a real stamp across the mask', () {
      // 41c99dc2's Rule-1 fix. It stops mattering for Modbus once the driver
      // stamps nothing, but it is exactly what a masked OPC UA key depends on,
      // and dropping it would be a silent regression with no arm on it.
      final source = _serverStamped()..statusCode = 0;
      final masked = StateMan.applyBitMask(source, 0x0002, 1);

      expect(masked.sourceTimestamp, _plantClock);
      expect(masked.statusCode, 0);
      // 42 == 0b101010, so bit 1 is set. A single-bit mask yields a bool.
      expect(masked.asBool, isTrue,
          reason: 'the mask still produced its value');
    });
  });

  group('direct mode: AlarmMan stamps from what the driver actually gave it',
      () {
    test('NEGATIVE: an unstamped Modbus binding is NOT labelled plant', () {
      final clock = CountingClock(_evaluationClock);

      // Exactly what alarm.dart:755 does: map the bound values' own
      // sourceTimestamps into resolveAlarmStamp.
      final stamp = resolveAlarmStamp(
        sourceTimes: <DateTime?>[
          ModbusDeviceClientAdapter.typedVariableToDynamicValue(
            TypedVariableValue(
                value: 7, typeName: 'INT', rawBytes: Uint8List(2)),
          ).sourceTimestamp,
        ],
        clock: clock,
      );

      expect(stamp.source, AlarmTsSource.backendReceipt);
      // The string that reaches alarm_history.ts_source.
      expect(stamp.source.wireName, 'backend_receipt');
      expect(stamp.source.wireName, isNot('plant'));
      // And the instant is the backend's own, openly: not the driver's read.
      expect(stamp.at, _evaluationClock);
      expect(stamp.at, isNot(_driverClock));
      expect(clock.reads, 1, reason: 'the clock was reached for, exactly once');
    });

    test('CONTROL: a genuine OPC UA binding IS labelled plant', () {
      final clock = CountingClock(_evaluationClock);

      final stamp = resolveAlarmStamp(
        sourceTimes: <DateTime?>[_serverStamped().sourceTimestamp],
        clock: clock,
        // The two fixtures are years apart on purpose; without this the CD-3
        // guard would fire and drown the arm in noise. It still must not clamp.
        skewWarnAfter: const Duration(days: 4000),
      );

      expect(stamp.source, AlarmTsSource.plant);
      expect(stamp.source.wireName, 'plant');
      expect(stamp.at, _plantClock);
      // Unchanged, not clamped to the receipt.
      expect(stamp.at, isNot(_evaluationClock));
    });

    test('NEGATIVE: one unstamped Modbus operand poisons a mixed rule', () {
      // The realistic SVN case: a rule binding a PLC tag and a Modbus tag. The
      // newest-wins rule (D-1) must not let the OPC UA operand carry the label
      // for a set that also contains an instant nobody vouched for.
      final clock = CountingClock(_evaluationClock);

      final stamp = resolveAlarmStamp(
        sourceTimes: <DateTime?>[_plantClock, null],
        clock: clock,
        skewWarnAfter: const Duration(days: 4000),
      );

      expect(stamp.source, AlarmTsSource.backendReceipt);
      expect(stamp.at, _evaluationClock);
    });
  });

  group('the pipe still gets a usable instant — staleness must not regress',
      () {
    test('an unstamped Modbus sample takes arrivedAt, and says it did', () {
      var fallbacks = 0;
      final translated = translateOpcUaSample(
        ModbusDeviceClientAdapter.typedVariableToDynamicValue(
          TypedVariableValue(
              value: 7, typeName: 'INT', rawBytes: Uint8List(2)),
        ),
        arrivedAt: _arrivedAt,
        onSourceTimeFallback: () => fallbacks++,
      );

      // Non-null: `t:` on the wire feeds the freshness badge, and blanking it
      // for the whole Modbus fleet would trade one lie for "age unknown".
      expect(translated.sourceTime, isNotNull);
      expect(translated.sourceTime, _arrivedAt);
      // And the substitution is reported rather than silent.
      expect(fallbacks, 1);
    });

    test('CONTROL: a server-stamped sample does not substitute', () {
      var fallbacks = 0;
      final translated = translateOpcUaSample(
        _serverStamped(),
        arrivedAt: _arrivedAt,
        onSourceTimeFallback: () => fallbacks++,
      );

      expect(translated.sourceTime, _plantClock);
      expect(translated.sourceTime, isNot(_arrivedAt));
      expect(fallbacks, 0);
    });
  });
}
