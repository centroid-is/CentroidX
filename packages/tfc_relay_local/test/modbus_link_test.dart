/// The Modbus/UMAS adapter, judged by the shared group and by the two facts
/// that are only true of this protocol.
///
/// **No `@TestOn`, no tag.** `opcua_link_test.dart` needs a real in-process
/// open62541 `Server` and is excluded from Windows for it; this file needs a
/// `DeviceClient`, which is an interface, so the whole thing runs on the vm
/// platform everywhere. That is not an accident of the fixture — it is the
/// reason 08-10 is small where 08-07 was large.
///
/// ## Why the shared group can run here and could not run against OPC UA
///
/// 08-07's named refutation stands: `UpstreamLinkDriver`'s levers are
/// synchronous `void` methods whose result the cases read on the very next
/// statement, and nothing backed by a socket can honour that. This subject is
/// backed by a `DeviceClient` **double**, which is in-memory, so every lever
/// is genuinely synchronous and the group is genuinely judging the adapter.
///
/// What it is judging is the adapter's *surface* — resolve, peek, read, the
/// deadline, the write states, the degradation, the band guard, the epoch —
/// and not its wire translation, which is what the second half of this file
/// covers with real `ua.DynamicValue` samples. The two halves together are the
/// claim; either alone would be a subject asserting against its own shadow.
library;

import 'dart:async';

import 'package:open62541/open62541.dart' as ua;
import 'package:tfc_dart/core/modbus_client_wrapper.dart' show ModbusDataType;
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_dart/core/umas_types.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

import 'support/fake_upstream_link.dart';
import 'upstream_link_contract_test.dart'
    show contractFixtureKeys, runUpstreamLinkContract, setpointKey, speedKey;

/// This link's alias, in the plant's own spelling.
const String alias = 'ST101';

/// A key on a *different* PLC. 08-04's handoff is emphatic: the router does not
/// filter candidates by `server_alias`, so an adapter that claims anything
/// Modbus-shaped takes ST201's key on a two-PLC plant.
const String foreignAliasKey = 'ST201.CN04.MOT01.speed';

/// Generous: none of these cases is a latency measurement.
const Duration generous = Duration(seconds: 5);

/// A classic-Modbus mapping entry — the register-spec route.
KeyMappingEntry registerEntry(String key,
        {String? serverAlias = alias, int? bitMask, int? bitShift}) =>
    KeyMappingEntry(
      modbusNode: ModbusNodeConfig(
        serverAlias: serverAlias,
        registerType: ModbusRegisterType.holdingRegister,
        address: 100,
        dataType: ModbusDataType.uint16,
        pollGroup: 'fast',
      ),
      bitMask: bitMask,
      bitShift: bitShift,
    );

/// A UMAS-by-symbol mapping entry — the `variable_name` route.
KeyMappingEntry umasEntry(String key,
        {String? serverAlias = alias, String symbol = 'M_Elevator.i_isAuto'}) =>
    KeyMappingEntry(
      modbusNode: ModbusNodeConfig(
        serverAlias: serverAlias,
        registerType: ModbusRegisterType.holdingRegister,
        address: 0,
        dataType: ModbusDataType.uint16,
        pollGroup: 'slow',
      ),
      variableName: symbol,
    );

void main() {
  // ------------------------------------------------------------ the contract
  runUpstreamLinkContract(
      'ModbusUpstreamLink', () => DrivableModbusLink(alias: alias));

  // --------------------------------------------- what is only true of Modbus

  group('resolve routes both address spaces and no other PLC\'s', () {
    late DrivableModbusLink link;

    setUp(() async {
      link = DrivableModbusLink(alias: alias);
      await link.connect(deadline: generous);
      addTearDown(link.dispose);
    });

    test('a register spec routes', () {
      final ref = link.resolve(speedKey, registerEntry(speedKey));

      expect(ref, isNotNull);
      expect(ref!.payload, 'holdingRegister:100',
          reason: 'the payload is what the adapter needs to reach the point, '
              'and nothing outside the adapter interprets it');
    });

    test('a variable_name routes, and carries the symbol', () {
      final ref = link.resolve(setpointKey,
          umasEntry(setpointKey, symbol: 'M_Elevator.i_isAuto'));

      expect(ref, isNotNull);
      expect(ref!.payload, 'M_Elevator.i_isAuto',
          reason: 'UMAS by symbol is a different address space, not a '
              'different link — Schneider only exposes %MW-located variables '
              'on the FC03 map, so the symbol IS the address');
    });

    test('another PLC\'s key is not claimed', () {
      expect(
          link.resolve(
              foreignAliasKey, registerEntry(foreignAliasKey, serverAlias: 'ST201')),
          isNull,
          reason: 'the router offers the key to every link in order and takes '
              'the first claim; an adapter that does not check its own alias '
              'takes ST201\'s key and the router\'s ambiguity check cannot see '
              'it, because the two links have different aliases');
    });

    test('an entry with no modbus node is not claimed', () {
      expect(link.resolve(speedKey, KeyMappingEntry()), isNull);
    });

    test('a non-KeyMappingEntry is not claimed rather than thrown at', () {
      expect(link.resolve(speedKey, const <String, Object?>{'nope': 1}), isNull,
          reason: 'null is "not mine". A throw here would make the router\'s '
              'fallthrough order a try/catch ladder');
    });

    test('the configured poll group passes through unchanged', () {
      link.resolve(speedKey, registerEntry(speedKey));
      link.resolve(setpointKey, umasEntry(setpointKey));

      expect(link.pollGroupOf(speedKey), 'fast');
      expect(link.pollGroupOf(setpointKey), 'slow',
          reason: 'the adapter below already owns per-poll-group timers and '
              'the batched MonitorPlc table; re-deriving the grouping here '
              'would be a second opinion about a cadence that is configured '
              'once');
    });
  });

  group('a Modbus value is stamped with its arrival, and says so', () {
    late DrivableModbusLink link;

    setUp(() async {
      link = DrivableModbusLink(alias: alias);
      await link.connect(deadline: generous);
      addTearDown(link.dispose);
    });

    test('a sample with no source timestamp is stamped now, and counted', () {
      final before = DateTime.now().toUtc();

      final translated = link.translateSampleForTest(
          ua.DynamicValue(value: 42), arrivedAt: DateTime.now().toUtc());

      final after = DateTime.now().toUtc();
      expect(translated.value, 42);
      expect(translated.quality, Quality.good);
      expect(
          translated.sourceTime!.isBefore(before.subtract(
              const Duration(milliseconds: 1))),
          isFalse,
          reason: 'Modbus has no source timestamp on the wire. The honest '
              'thing is to stamp arrival and say so — not to pretend the '
              'register carried an instant it never did');
      expect(
          translated.sourceTime!.isAfter(after.add(const Duration(seconds: 1))),
          isFalse);
      expect(link.arrivalStampedSamples, 1,
          reason: 'the counter is the difference between a mitigation and a '
              'hope (T-08-25). Contrast the OPC UA link, whose sourceTime is '
              'the server\'s own and whose sourceTimeFallbacks counter is '
              'expected to stay at zero against a healthy PLC');
    });

    test('a sample that DOES carry an instant keeps it, and is not counted',
        () {
      final stamped = DateTime.utc(2026, 9, 1, 12);

      final translated = link.translateSampleForTest(
          ua.DynamicValue(value: 7)..sourceTimestamp = stamped,
          arrivedAt: DateTime.now().toUtc());

      expect(translated.sourceTime, stamped);
      expect(link.arrivalStampedSamples, 0,
          reason: 'the anti-vacuity arm: a counter that ticks for every sample '
              'measures nothing');
    });

    test('a sample that will not sanitize costs one tag, not the poll cycle',
        () {
      Object? nested = 1;
      for (var i = 0; i < 70; i++) {
        nested = <String, Object?>{'n': nested};
      }

      final translated = link.translateSampleForTest(
          ua.DynamicValue(value: nested), arrivedAt: DateTime.now().toUtc());

      expect(translated.quality, Quality.errorConfig);
      expect(translated.value, isNull);
    });
  });

  group('link state comes from the adapter\'s effective status', () {
    test('connected-but-UMAS-unhealthy is unhealthy, never connected', () async {
      final link = DrivableModbusLink(alias: alias);
      await link.connect(deadline: generous);
      addTearDown(link.dispose);

      link.pushEffectiveStatus(EffectiveDeviceStatus.umasUnhealthy);

      expect(link.state, UpstreamLinkState.unhealthy,
          reason: 'TD-004: a PLC with the Data Dictionary disabled renders as '
              'a green Connected chip while every UMAS key card shows a red '
              'error badge. Collapsing the two puts a green badge on a screen '
              'full of values nobody has measured');
    });

    test('the three TCP states map straight through', () async {
      final link = DrivableModbusLink(alias: alias);
      await link.connect(deadline: generous);
      addTearDown(link.dispose);

      link.pushEffectiveStatus(EffectiveDeviceStatus.connecting);
      expect(link.state, UpstreamLinkState.connecting);
      link.pushEffectiveStatus(EffectiveDeviceStatus.disconnected);
      expect(link.state, UpstreamLinkState.disconnected);
      link.pushEffectiveStatus(EffectiveDeviceStatus.connected);
      expect(link.state, UpstreamLinkState.connected);
    });

    test('the production wiring listens to the adapter\'s status stream',
        () async {
      // Every other case in this file invokes `onEffectiveStatus` directly,
      // because the shared group's levers are synchronous. This one goes the
      // long way round — an emission on the adapter's own
      // `effectiveStatusStream` — so the subscription `connect()` takes out is
      // proved rather than assumed. Without it the whole file could pass
      // against a link that never listened to anything.
      final link = DrivableModbusLink(alias: alias);
      await link.connect(deadline: generous);
      addTearDown(link.dispose);
      expect(link.state, UpstreamLinkState.connected);

      link.fake.emitEffective(EffectiveDeviceStatus.disconnected);
      await pumpEventQueue();

      expect(link.state, UpstreamLinkState.disconnected);
    });
  });

  group('the write path answers in three states and never in exceptions', () {
    late DrivableModbusLink link;

    setUp(() async {
      link = DrivableModbusLink(alias: alias);
      await link.connect(deadline: generous);
      addTearDown(link.dispose);
    });

    test('a typed UmasException is a REJECTION with the code in status',
        () async {
      final ref = link.resolve(setpointKey, umasEntry(setpointKey))!;
      link.fake.failWriteWith(
          const UmasException(errorCode: 0x0B, message: 'variable is read only'));

      final result = await link.write(ref, DynamicValue.of(1),
          cmd: 'cmd-umas', deadline: generous);

      expect(result, isA<WriteRejected>(),
          reason: 'a typed UMAS code is the device declining by name, the same '
              'as a Modbus exception PDU — there is no service layer above the '
              'write that could fail after the variable moved');
      expect((result as WriteRejected).reason.status, 'Umas_0x0b');
      expect(result.reason.kind, 'device_refused');
    });

    test('a write that never answers inside the deadline is UNKNOWN', () async {
      final ref = link.resolve(setpointKey, registerEntry(setpointKey))!;
      link.writeLatency = const Duration(seconds: 30);

      final result = await link
          .write(ref, DynamicValue.of(1),
              cmd: 'cmd-slow', deadline: const Duration(milliseconds: 20))
          .timeout(const Duration(seconds: 2),
              onTimeout: () => fail('write outran its own deadline'));

      expect(result, isA<WriteUnknown>(),
          reason: '"it did not happen" and "I cannot tell whether it happened" '
              'are different things to tell an operator standing next to the '
              'machine');
    });

    test('an untyped throw is UNKNOWN, not rejected', () async {
      final ref = link.resolve(setpointKey, registerEntry(setpointKey))!;
      link.fake.failWriteWith(
          const SocketFailure('connection reset by peer 10.104.29.11:502'));

      final result = await link.write(ref, DynamicValue.of(1),
          cmd: 'cmd-reset', deadline: generous);

      expect(result, isA<WriteUnknown>(),
          reason: 'assumption A3\'s safe half: a sentence this gateway cannot '
              'read as a refusal is not evidence of one, and "rejected" is the '
              'one answer that invites a second press of the button');
      expect((result as WriteUnknown).reason.message, isNot(contains('10.104.29.11')),
          reason: 'the message becomes PIPE.upstream.<alias>.last_error, which '
              'any panel may subscribe to (T-08-08)');
    });

    test('a bit-masked key refuses without an expect', () async {
      final ref = link.resolve(
          setpointKey, registerEntry(setpointKey, bitMask: 0x0004, bitShift: 2))!;

      final result = await link.write(ref, DynamicValue.of(true),
          cmd: 'cmd-bit', deadline: generous);

      expect(result, isA<WriteRejected>(),
          reason: 'a bit-masked Modbus write is a read-modify-write of the '
              'whole register (modbus_device_client.dart:1240-1252) and is not '
              'atomic — the same hazard guardArrayElementWrite was written for, '
              'at the one layer where the mask is visible');
      expect((result as WriteRejected).reason.kind,
          'array_element_requires_expect');
      expect(link.fake.writes, isEmpty,
          reason: 'the refusal happens BEFORE anything is sent');
    });

    test('WR-02: and it APPLIES with one, which is the escape the refusal '
        'message tells the operator to take', () async {
      final ref = link.resolve(
          setpointKey, registerEntry(setpointKey, bitMask: 0x0004, bitShift: 2))!;

      final result = await link.write(ref, DynamicValue.of(true),
          cmd: 'cmd-bit-expect', deadline: generous, hasExpect: true);

      expect(result, isA<WriteApplied>(),
          reason: 'guardArrayElementWrite documents "with an expect present '
              'the read-modify-write may run, with the comparison as its '
              'guard", and the one call site passed the literal false. The '
              'result was fail-safe, but the documented capability was '
              'unreachable and the refusal told an operator who HAD supplied '
              'expect to supply expect — a message that sends them hunting a '
              'mistake they did not make');
      expect(link.fake.writes, hasLength(1),
          reason: 'and the guarded write genuinely reaches the device');
    });

    test('a plain register write applies and reaches the adapter once',
        () async {
      final ref = link.resolve(setpointKey, registerEntry(setpointKey))!;

      final result = await link.write(ref, DynamicValue.of(5),
          cmd: 'cmd-ok', deadline: generous);

      expect(result, isA<WriteApplied>());
      expect(link.fake.writes, hasLength(1),
          reason: 'ONE crossing into the plant. No retry shape anywhere near '
              'it — readback is the only confirmation');
    });
  });
}

/// A throw with no code in it, of the kind `dart:io` produces.
class SocketFailure implements Exception {
  const SocketFailure(this.message);
  final String message;
  @override
  String toString() => 'SocketException: $message';
}

/// The `ModbusDeviceClientAdapter`-shaped double.
///
/// It implements the two interfaces the link consumes — `DeviceClient` and
/// [EffectiveStatusSource] — rather than extending the 1,506-line adapter,
/// because those two are the entire contact surface and a double that
/// re-implemented M580 quirks would be testing itself.
final class FakeModbusDeviceClient implements DeviceClient, EffectiveStatusSource {
  final Map<String, StreamController<ua.DynamicValue>> _feeds =
      <String, StreamController<ua.DynamicValue>>{};
  final Map<String, ua.DynamicValue> _last = <String, ua.DynamicValue>{};
  final StreamController<ConnectionStatus> _tcp =
      StreamController<ConnectionStatus>.broadcast();
  final StreamController<EffectiveDeviceStatus> _effective =
      StreamController<EffectiveDeviceStatus>.broadcast();

  /// Every `(key, value)` this double was asked to write. The count that makes
  /// "no retry" falsifiable.
  final List<({String key, ua.DynamicValue value})> writes =
      <({String key, ua.DynamicValue value})>[];

  ConnectionStatus _status = ConnectionStatus.disconnected;
  EffectiveDeviceStatus _effectiveStatus = EffectiveDeviceStatus.disconnected;
  Object? _writeFailure;

  /// How long a write takes before it answers. The only way to test a deadline
  /// is to be slower than one.
  Duration writeLatency = Duration.zero;

  void failWriteWith(Object error) => _writeFailure = error;

  void clearWriteFailure() => _writeFailure = null;

  /// Sets the health the link reads synchronously.
  ///
  /// **Deliberately silent on [effectiveStatusStream].** A driver that both
  /// emitted on the stream and invoked the handler would deliver every
  /// transition twice — once now and once on the next event-loop turn — and the
  /// shared group's `stateStream` case, which asserts an exact list, is what
  /// caught it. The stream wiring is proved separately by
  /// `the production wiring listens to the adapter's status stream`.
  void pushEffective(EffectiveDeviceStatus status) => _effectiveStatus = status;

  /// Emits on the health stream **without** touching the handler, which is what
  /// the real adapter does.
  void emitEffective(EffectiveDeviceStatus status) {
    _effectiveStatus = status;
    if (!_effective.isClosed) _effective.add(status);
  }

  @override
  Set<String> get subscribableKeys => _feeds.keys.toSet();

  @override
  bool canSubscribe(String key) => true;

  @override
  Stream<ua.DynamicValue> subscribe(String key) => _feeds
      .putIfAbsent(key, () => StreamController<ua.DynamicValue>.broadcast())
      .stream;

  @override
  ua.DynamicValue? read(String key) => _last[key];

  @override
  ConnectionStatus get connectionStatus => _status;

  @override
  Stream<ConnectionStatus> get connectionStream => _tcp.stream;

  @override
  EffectiveDeviceStatus get effectiveStatus => _effectiveStatus;

  @override
  Stream<EffectiveDeviceStatus> get effectiveStatusStream => _effective.stream;

  @override
  void connect() {
    _status = ConnectionStatus.connected;
    if (!_tcp.isClosed) _tcp.add(_status);
    pushEffective(EffectiveDeviceStatus.connected);
  }

  @override
  Future<void> write(String key, ua.DynamicValue value) async {
    if (writeLatency > Duration.zero) {
      await Future<void>.delayed(writeLatency);
    }
    final failure = _writeFailure;
    if (failure != null) {
      _writeFailure = null;
      throw failure;
    }
    writes.add((key: key, value: value));
    _last[key] = value;
  }

  @override
  void dispose() {
    for (final feed in _feeds.values) {
      if (!feed.isClosed) feed.close();
    }
    if (!_tcp.isClosed) _tcp.close();
    if (!_effective.isClosed) _effective.close();
  }
}

/// The production link plus the control surface the shared group needs.
///
/// **Every lever below drives a `@protected` entry point the production code
/// already uses**, or the double underneath it. None of them is a second code
/// path: `disconnectUpstream` calls the same `onEffectiveStatus` the adapter's
/// status stream calls, `setValue` calls the same `deliver` the sample
/// listener calls. A driver that reached past the link into its cache would be
/// asserting against its own writes.
final class DrivableModbusLink extends ModbusUpstreamLink
    implements UpstreamLinkDriver {
  factory DrivableModbusLink(
          {required String alias, FakeModbusDeviceClient? client}) =>
      DrivableModbusLink._(alias, client ?? FakeModbusDeviceClient());

  DrivableModbusLink._(String alias, FakeModbusDeviceClient double_)
      : fake = double_,
        super(alias: alias, client: double_, health: double_);

  /// The double underneath, for the cases that count what reached the wire.
  final FakeModbusDeviceClient fake;

  bool _failNextResolve = false;
  bool _writes = true;
  bool _browse = false;
  Duration _readLatency = Duration.zero;

  final List<({String key, Object? raw})> _rawEmissions =
      <({String key, Object? raw})>[];

  /// The mapping entries the shared group cannot supply: it hands `resolve` an
  /// opaque `Map` on purpose (the entry is the adapter's business), so the
  /// subject supplies the real one for the two fixture keys and nothing for
  /// any other.
  static final Map<String, KeyMappingEntry> _fixtureEntries =
      <String, KeyMappingEntry>{
    for (final key in contractFixtureKeys) key: registerEntry(key),
  };

  @override
  UpstreamRef? resolve(String key, Object mappingEntry) {
    if (_failNextResolve) {
      _failNextResolve = false;
      return null;
    }
    if (mappingEntry is KeyMappingEntry) return super.resolve(key, mappingEntry);
    // **Only the shared group's own opaque placeholder is substituted**, which
    // is the empty map `upstream_link_contract_test.dart:44` declares. Any
    // other non-entry goes straight to production `resolve`, so the case that
    // asserts "a non-KeyMappingEntry is not claimed" is judging the adapter and
    // not this override.
    if (mappingEntry is! Map || mappingEntry.isNotEmpty) {
      return super.resolve(key, mappingEntry);
    }
    final entry = _fixtureEntries[key];
    if (entry == null) return null;
    return super.resolve(key, entry);
  }

  @override
  bool get supportsWrites => _writes;

  @override
  bool get supportsBrowse => _browse;

  // ----------------------------------------------------------- the nine kit

  @override
  void setValue(String key, Object? value,
      {Quality quality = Quality.good, DateTime? sourceTime}) {
    deliver(
        key,
        DynamicValue(
            value: value,
            quality: quality,
            sourceTime: sourceTime ?? DateTime.now().toUtc()));
  }

  @override
  void setValues(Map<String, Object?> values) {
    values.forEach((key, value) => setValue(key, value));
  }

  @override
  void setQuality(String key, Quality quality) {
    final current = peekCached(key);
    deliver(
        key,
        DynamicValue(
            value: current?.value,
            quality: quality,
            sourceTime: current?.sourceTime ?? DateTime.now().toUtc()));
  }

  @override
  void dropKey(String key) => dropKeyUpstream(key);

  @override
  void disconnectUpstream() {
    fake.pushEffective(EffectiveDeviceStatus.disconnected);
    onEffectiveStatus(EffectiveDeviceStatus.disconnected);
  }

  @override
  void reconnectUpstream() {
    fake.pushEffective(EffectiveDeviceStatus.connected);
    onEffectiveStatus(EffectiveDeviceStatus.connected);
  }

  /// Pushes a status the way the adapter's own stream would.
  void pushEffectiveStatus(EffectiveDeviceStatus status) {
    fake.pushEffective(status);
    onEffectiveStatus(status);
  }

  @override
  int get roundTrips => upstreamRoundTrips;

  @override
  int get statusNotifications => stateAnnouncements;

  // ---------------------------------------------------------- this phase's

  @override
  void bumpEpoch() => bumpEpochTo('e1:driven-${DateTime.now().microsecondsSinceEpoch}');

  @override
  void setNextWriteOutcome(WriteResult outcome) {
    switch (outcome) {
      case WriteApplied():
      case WriteNotReceived():
        fake.clearWriteFailure();
      case WriteRejected():
        fake.failWriteWith(
            const UmasException(errorCode: 0x0B, message: 'staged refusal'));
      case WriteUnknown():
        fake.failWriteWith(TimeoutException('staged unknown'));
    }
  }

  @override
  Duration get readLatency => _readLatency;

  @override
  set readLatency(Duration value) => _readLatency = value;

  @override
  Duration get writeLatency => fake.writeLatency;

  @override
  set writeLatency(Duration value) => fake.writeLatency = value;

  @override
  void failNextResolve() => _failNextResolve = true;

  @override
  void setSupportsWrites(bool value) => _writes = value;

  @override
  void setSupportsBrowse(bool value) => _browse = value;

  @override
  void emitRaw(String key, Object? raw) {
    _rawEmissions.add((key: key, raw: raw));
    deliverRaw(key, raw, arrivedAt: DateTime.now().toUtc());
  }

  @override
  List<({String key, Object? raw})> get rawEmissions =>
      List<({String key, Object? raw})>.unmodifiable(_rawEmissions);

  @override
  void setLastError(String? raw) {
    if (raw != null) recordUpstreamError(raw);
  }

  @override
  Future<DynamicValue?> roundTrip(String key) async {
    if (_readLatency > Duration.zero) {
      await Future<void>.delayed(_readLatency);
    }
    return super.roundTrip(key);
  }

  /// The production translation, reachable from a case.
  DynamicValue translateSampleForTest(ua.DynamicValue sample,
          {required DateTime arrivedAt}) =>
      translateSample(sample, arrivedAt: arrivedAt);
}
