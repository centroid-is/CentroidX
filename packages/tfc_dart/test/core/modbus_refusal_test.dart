/// A Modbus exception response is AFFIRMATIVE information, and must not be
/// graded the same as silence.
///
/// **The finding, measured by the 200-server bench:** a register the server
/// answers with `IllegalDataAddress` produced no sample, no error and no log
/// line — the key sat at `uncertainNotYetKnown` (258) for the life of the
/// process, indistinguishable from "merely late". But the far end *actively
/// told us the truth*: it parsed the request and refused the address. That is
/// the opposite of silence, and dropping it is the quiet-lie failure this
/// milestone exists to end.
///
/// **The repair under test:** `ModbusClientWrapper` names the refusal on a
/// dedicated [ModbusClientWrapper.refusals] stream — once per transition, not
/// once per poll tick, because a permanently refused register polled at 20 Hz
/// must not be its own denial-of-service (this repo has been bitten by
/// hot-path logging before). Transport failures (timeout, connection lost) are
/// NOT refusals: nothing came back, the link machinery owns those, and the
/// existing skip-and-keep-last-value behaviour stands.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:modbus_client/modbus_client.dart';
import 'package:modbus_client_tcp/modbus_client_tcp.dart';
import 'package:tfc_dart/core/modbus_client_wrapper.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:test/test.dart';

class MockModbusClient extends ModbusClientTcp {
  bool _connected = false;
  ModbusResponseCode Function(ModbusRequest request)? onSend;

  MockModbusClient()
      : super('mock',
            serverPort: 0,
            connectionMode: ModbusConnectionMode.doNotConnect);

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
    if (onSend != null) return onSend!(request);
    return ModbusResponseCode.requestSucceed;
  }
}

/// Fills a group read with [word] in every register.
ModbusResponseCode succeedWith(ModbusRequest request, int word) {
  if (request is ModbusReadGroupRequest) {
    final n = request.elementGroup.addressRange * 2;
    final bytes = Uint8List(n);
    for (var i = 0; i + 1 < n; i += 2) {
      bytes[i] = (word >> 8) & 0xFF;
      bytes[i + 1] = word & 0xFF;
    }
    request.internalSetElementData(bytes);
  }
  return ModbusResponseCode.requestSucceed;
}

const spec = ModbusRegisterSpec(
  key: 'illegal',
  registerType: ModbusElementType.holdingRegister,
  address: 10,
  pollGroup: 'fast',
);

({ModbusClientWrapper wrapper, MockModbusClient mock}) build() {
  final mock = MockModbusClient();
  final wrapper = ModbusClientWrapper('h', 502, 1,
      clientFactory: (_, __, ___) => mock,
      heartbeatInterval: const Duration(hours: 1));
  wrapper.addPollGroup('fast', const Duration(milliseconds: 30));
  return (wrapper: wrapper, mock: mock);
}

void main() {
  test(
      'IllegalDataAddress is named on the refusals stream — ONCE per '
      'transition, however many polls repeat it — and no value is published',
      () async {
    final built = build();
    addTearDown(built.wrapper.dispose);
    built.mock.onSend = (_) => ModbusResponseCode.illegalDataAddress;

    final samples = <Object?>[];
    final refusals = <ModbusAddressRefusal>[];
    built.wrapper.subscribe(spec).listen(samples.add);
    built.wrapper.refusals.listen(refusals.add);
    built.wrapper.connect();
    // ~8 poll ticks: the dedup has to survive repetition to mean anything.
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(samples, isEmpty,
        reason: 'a refused read must not invent a value — the existing '
            'no-publish behaviour stands');
    expect(refusals, hasLength(1),
        reason: 'once per transition, never per tick: a permanently refused '
            'register at poll rate is its own denial of service');
    expect(refusals.single.key, 'illegal');
    expect(refusals.single.code, ModbusResponseCode.illegalDataAddress);
  });

  test('neither silence nor a busy device is a refusal — only the codes '
      'where the device declined the request\'s SHAPE', () async {
    final built = build();
    addTearDown(built.wrapper.dispose);
    // Silence first — briefly, deliberately under the wrapper's three-
    // consecutive-failures half-open threshold, because tripping the
    // reconnect loop would make this case about backoff instead.
    built.mock.onSend = (_) => ModbusResponseCode.requestTimeout;

    final refusals = <ModbusAddressRefusal>[];
    built.wrapper.refusals.listen(refusals.add);
    built.wrapper.subscribe(spec).listen((_) {});
    built.wrapper.connect();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(refusals, isEmpty,
        reason: 'grading silence as an affirmative refusal is the same lie '
            'with the polarity flipped: the link machinery owns transports');

    // Then an ANSWERED exception that is still not a refusal: deviceBusy is
    // a statement about the moment, not the register map.
    built.mock.onSend = (_) => ModbusResponseCode.deviceBusy;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(refusals, isEmpty,
        reason: 'a busy device recovers by waiting — exactly what a refusal '
            'never does, and exactly why the two must not share a grade');

    // The live control that proves the observer works: the same wrapper, the
    // same subscription, and the answer changes to a refusal.
    built.mock.onSend = (_) => ModbusResponseCode.illegalDataAddress;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(refusals, hasLength(1));
  });

  test('a refusal CLEARS on success and is named again on the next refusal — '
      'the stream reports transitions, not a latch', () async {
    final built = build();
    addTearDown(built.wrapper.dispose);
    built.mock.onSend = (_) => ModbusResponseCode.illegalDataAddress;

    final samples = <Object?>[];
    final refusals = <ModbusAddressRefusal>[];
    built.wrapper.subscribe(spec).listen(samples.add);
    built.wrapper.refusals.listen(refusals.add);
    built.wrapper.connect();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(refusals, hasLength(1));

    // The register map is fixed (or the PLC reprogrammed): values flow again.
    built.mock.onSend = (r) => succeedWith(r, 7);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(samples, isNotEmpty,
        reason: 'recovery must be the ordinary good path — a latched refusal '
            'would hold a fixed register at an error forever');

    // And a NEW refusal after the recovery is a new fact, named again.
    built.mock.onSend = (_) => ModbusResponseCode.illegalDataAddress;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(refusals, hasLength(2));
  });

  test('the adapter re-exposes the wrapper\'s refusals unchanged', () async {
    final built = build();
    built.mock.onSend = (_) => ModbusResponseCode.illegalDataAddress;
    final adapter = ModbusDeviceClientAdapter(built.wrapper,
        specs: const {'illegal': spec}, serverAlias: 'ST101');
    addTearDown(adapter.dispose);

    final refusals = <ModbusAddressRefusal>[];
    adapter.registerRefusals.listen(refusals.add);
    adapter.subscribe('illegal').listen((_) {});
    adapter.connect();
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(refusals, hasLength(1),
        reason: 'the seam the upstream link consumes: one getter, no second '
            'vocabulary');
    expect(refusals.single.key, 'illegal');
  });
}
