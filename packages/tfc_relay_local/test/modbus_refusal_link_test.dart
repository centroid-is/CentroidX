/// A refused Modbus address reads as `errorConfig` on the pipe — because the
/// device SAID no, and "the upstream affirmatively said no" is exactly what
/// 770 means.
///
/// The bench's `Illegal` register: the server answers `IllegalDataAddress` on
/// every poll and the key sat at `uncertainNotYetKnown` forever. 258 means
/// "waiting does fix this"; for a register the device refuses by name, waiting
/// fixes nothing — the register map is wrong, and somebody must go fix the
/// config. That is [Quality.errorConfig]'s sentence verbatim, so the existing
/// band is used rather than a new one invented.
///
/// Two subjects here:
///
///  * [ModbusUpstreamLink] with an injected refusal stream — the unit arms,
///    including both polarities;
///  * the REAL `wrapper → adapter → link` stack over a mock socket — the
///    production `.wrapping` wiring, so a sabotage that drops the
///    `refusals:` argument from the factory reddens something.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:modbus_client/modbus_client.dart';
import 'package:modbus_client_tcp/modbus_client_tcp.dart';
import 'package:open62541/open62541.dart' as ua;
import 'package:tfc_dart/core/modbus_client_wrapper.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

const String alias = 'ST101';
const String illegalKey = 'ST101.CN01.MOT01.illegal';
const String plainKey = 'ST101.CN01.MOT01.speed';
const Duration generous = Duration(seconds: 5);

KeyMappingEntry registerEntry(String key, {int address = 100}) =>
    KeyMappingEntry(
      modbusNode: ModbusNodeConfig(
        serverAlias: alias,
        registerType: ModbusRegisterType.holdingRegister,
        address: address,
        dataType: ModbusDataType.uint16,
        pollGroup: 'fast',
      ),
    );

/// The link never touches the wire in the unit arms; the refusal stream is
/// the whole subject.
final class _InertClient implements DeviceClient {
  final Map<String, StreamController<ua.DynamicValue>> _feeds =
      <String, StreamController<ua.DynamicValue>>{};

  @override
  Set<String> get subscribableKeys => _feeds.keys.toSet();
  @override
  bool canSubscribe(String key) => true;
  @override
  Stream<ua.DynamicValue> subscribe(String key) => _feeds
      .putIfAbsent(key, () => StreamController<ua.DynamicValue>.broadcast())
      .stream;
  @override
  ua.DynamicValue? read(String key) => null;
  @override
  ConnectionStatus get connectionStatus => ConnectionStatus.connected;
  @override
  Stream<ConnectionStatus> get connectionStream => const Stream.empty();
  @override
  void connect() {}
  @override
  Future<void> write(String key, ua.DynamicValue value) async {}
  @override
  void dispose() {}
}

void main() {
  group('the unit arms: an injected refusal grades the key', () {
    late StreamController<ModbusAddressRefusal> refusals;
    late ModbusUpstreamLink link;

    setUp(() async {
      refusals = StreamController<ModbusAddressRefusal>.broadcast();
      link = ModbusUpstreamLink(
        alias: alias,
        client: _InertClient(),
        refusals: refusals.stream,
      );
      await link.connect(deadline: generous);
      addTearDown(() async {
        await link.dispose();
        await refusals.close();
      });
    });

    ModbusAddressRefusal refusalOf(String key) => ModbusAddressRefusal(
          key: key,
          code: ModbusResponseCode.illegalDataAddress,
          at: DateTime.now().toUtc(),
        );

    test('a refusal is errorConfig with a null payload, streamed and cached',
        () async {
      final ref = link.resolve(illegalKey, registerEntry(illegalKey))!;
      final events = <DynamicValue>[];
      link.subscribe(ref).listen(events.add);

      refusals.add(refusalOf(illegalKey));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(events, hasLength(1));
      expect(events.single.quality, Quality.errorConfig,
          reason: 'the device parsed the request and said no — a config '
              'error, not a transient, and 258 would instruct the operator '
              'to keep waiting for a register that is never coming');
      expect(events.single.value, isNull,
          reason: 'nothing was read; a payload here would be an invention');
      expect(link.peek(ref)!.quality, Quality.errorConfig,
          reason: 'a page opened later reads peek and must see the verdict');
      expect(link.lastError, isNotNull,
          reason: 'the link health surface carries the reason an engineer '
              'reads');
    });

    test('the same refusal twice is one event — the guard, not the caller, '
        'owns the dedup', () async {
      final ref = link.resolve(illegalKey, registerEntry(illegalKey))!;
      final events = <DynamicValue>[];
      link.subscribe(ref).listen(events.add);

      refusals.add(refusalOf(illegalKey));
      refusals.add(refusalOf(illegalKey));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(events, hasLength(1));
    });

    test('BOTH polarities: the un-refused key beside it stays silent',
        () async {
      final refIllegal = link.resolve(illegalKey, registerEntry(illegalKey))!;
      final refPlain =
          link.resolve(plainKey, registerEntry(plainKey, address: 101))!;
      final illegalEvents = <DynamicValue>[];
      final plainEvents = <DynamicValue>[];
      link.subscribe(refIllegal).listen(illegalEvents.add);
      link.subscribe(refPlain).listen(plainEvents.add);

      refusals.add(refusalOf(illegalKey));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(illegalEvents.map((e) => e.quality),
          contains(Quality.errorConfig));
      expect(plainEvents, isEmpty,
          reason: 'a key that merely has not arrived yet must STILL read '
              'not-yet-known — painting the neighbour red is the loud lie');
      expect(link.peek(refPlain), isNull);
    });
  });

  group('the production wiring: wrapper → adapter → .wrapping', () {
    test('a mock socket answering IllegalDataAddress comes out of the link '
        'as errorConfig', () async {
      final mock = _MockModbusClient();
      mock.onSend = (_) => ModbusResponseCode.illegalDataAddress;
      final wrapper = ModbusClientWrapper('h', 502, 1,
          clientFactory: (_, __, ___) => mock,
          heartbeatInterval: const Duration(hours: 1));
      wrapper.addPollGroup('fast', const Duration(milliseconds: 30));
      final adapter = ModbusDeviceClientAdapter(wrapper, specs: const {
        illegalKey: ModbusRegisterSpec(
          key: illegalKey,
          registerType: ModbusElementType.holdingRegister,
          address: 100,
          pollGroup: 'fast',
        ),
      }, serverAlias: alias);
      final link = ModbusUpstreamLink.wrapping(adapter, alias: alias);
      addTearDown(link.dispose);

      await link.connect(deadline: generous);
      final ref = link.resolve(illegalKey, registerEntry(illegalKey))!;
      final events = <DynamicValue>[];
      link.subscribe(ref).listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(events.map((e) => e.quality), contains(Quality.errorConfig),
          reason: 'the whole production path: the factory must actually hand '
              'the adapter\'s refusal stream to the link');
      expect(events.where((e) => e.quality == Quality.errorConfig),
          hasLength(1),
          reason: 'once per transition end-to-end, though ~6 polls repeated '
              'the refusal');

      // Recovery through the same stack: the device starts serving the
      // register and the ordinary good path takes over.
      mock.onSend = (r) => _succeedWith(r, 7);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(events.last.quality, Quality.good,
          reason: 'a fixed register map must not stay latched at error');
      expect(events.last.value, 7);
    });
  });
}

class _MockModbusClient extends ModbusClientTcp {
  bool _connected = false;
  ModbusResponseCode Function(ModbusRequest request)? onSend;

  _MockModbusClient()
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

ModbusResponseCode _succeedWith(ModbusRequest request, int word) {
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
