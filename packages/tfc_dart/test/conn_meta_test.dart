import 'dart:async';

import 'package:test/test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc_dart/core/conn_meta.dart';
import 'package:tfc_dart/core/modbus_device_client.dart'
    show buildModbusDeviceClients;
import 'package:tfc_dart/core/state_man.dart'
    show
        KeyMappings,
        ModbusConfig,
        ModbusPollGroupConfig,
        StateMan,
        StateManConfig,
        StateManException;

/// A fully controllable [ConnMetaSource] for router/stream tests.
class FakeConnMetaSource implements ConnMetaSource {
  @override
  final String metaAlias;
  ConnMeta current;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  FakeConnMetaSource(this.metaAlias, this.current);

  @override
  bool get isModbus => current.isModbus;

  @override
  ConnMeta snapshot() => current;

  @override
  Stream<void> get changes => _changes.stream;

  void emitChange() => _changes.add(null);
  void dispose() => _changes.close();
}

ConnMeta modbusMeta({
  String state = 'connected',
  bool connected = true,
  String destIp = '10.0.0.5',
  int destPort = 502,
  double requestsPerSec = 0,
  int unitId = 1,
  int? sourcePort = 51234,
}) =>
    ConnMeta(
      isModbus: true,
      state: state,
      connected: connected,
      destIp: destIp,
      destPort: destPort,
      requestsPerSec: requestsPerSec,
      uptimeSec: 12.5,
      reconnectCount: 3,
      lastError: '',
      unitId: unitId,
      sourcePort: sourcePort,
      pollIntervalMs: 500,
    );

ConnMeta opcuaMeta() => const ConnMeta(
      isModbus: false,
      state: 'connected',
      connected: true,
      destIp: 'localhost',
      destPort: 4840,
      requestsPerSec: 4.0,
      uptimeSec: 30.0,
      reconnectCount: 1,
      lastError: 'boom',
      endpoint: 'opc.tcp://localhost:4840',
      channelState: 'UA_SECURECHANNELSTATE_OPEN',
      sessionState: 'UA_SESSIONSTATE_ACTIVATED',
      statusCode: 0,
      subscribedKeys: 7,
      lastDataAgeSec: 1.5,
    );

void main() {
  group('parseOpcEndpoint', () {
    test('host and explicit port', () {
      final r = parseOpcEndpoint('opc.tcp://192.168.0.10:4841/path');
      expect(r.host, '192.168.0.10');
      expect(r.port, 4841);
    });

    test('missing port defaults to 4840', () {
      final r = parseOpcEndpoint('opc.tcp://plc.local');
      expect(r.host, 'plc.local');
      expect(r.port, 4840);
    });

    test('host and port without path', () {
      final r = parseOpcEndpoint('opc.tcp://localhost:48010');
      expect(r.host, 'localhost');
      expect(r.port, 48010);
    });

    test('trailing path with default port', () {
      final r = parseOpcEndpoint('opc.tcp://server/UA/SampleServer');
      expect(r.host, 'server');
      expect(r.port, 4840);
    });

    test('IPv4 host with path', () {
      final r = parseOpcEndpoint('opc.tcp://127.0.0.1:4855/foo/bar');
      expect(r.host, '127.0.0.1');
      expect(r.port, 4855);
    });
  });

  group('RollingRate', () {
    test('reports per-second rate from a fed counter with a fake clock', () {
      var now = DateTime(2020);
      final rate = RollingRate(windowSeconds: 5, clock: () => now);

      expect(rate.ratePerSec, 0);

      // 10 requests within the first second.
      for (var i = 0; i < 10; i++) {
        rate.increment();
      }
      now = now.add(const Duration(seconds: 1));
      expect(rate.ratePerSec, 10);

      // An idle second folds a 0 into the window → avg of [10, 0] = 5.
      now = now.add(const Duration(seconds: 1));
      expect(rate.ratePerSec, 5);

      // Another 20 over the next second → window [10, 0, 20] avg = 10.
      for (var i = 0; i < 20; i++) {
        rate.increment();
      }
      now = now.add(const Duration(seconds: 1));
      expect(rate.ratePerSec, closeTo(10, 0.0001));
    });

    test(
        'a gap longer than the window resets it in O(window) — no '
        'O(uptime) zero back-fill, no bogus spike from the gap delta', () {
      var now = DateTime(2020);
      final rate = RollingRate(windowSeconds: 5, clock: () => now);

      // Steady traffic, then nobody reads the rate for 30 days.
      rate.increment(50);
      now = now.add(const Duration(seconds: 1));
      expect(rate.ratePerSec, 50);
      rate.increment(180000);
      now = now.add(const Duration(days: 30));

      // First read after the gap: fresh window, so 0 — not the gap's
      // 180000 requests attributed to a single second, and without
      // 2.6 million queued zeros.
      final sw = Stopwatch()..start();
      expect(rate.ratePerSec, 0);
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(50));

      // And it converges immediately on the next real second.
      rate.increment(40);
      now = now.add(const Duration(seconds: 1));
      expect(rate.ratePerSec, 40);
    });

    test('window drops old samples', () {
      var now = DateTime(2020);
      final rate = RollingRate(windowSeconds: 2, clock: () => now);
      rate.increment(100);
      now = now.add(const Duration(seconds: 1));
      expect(rate.ratePerSec, 100); // [100]
      now = now.add(const Duration(seconds: 1));
      expect(rate.ratePerSec, 50); // [100, 0]
      now = now.add(const Duration(seconds: 1));
      expect(rate.ratePerSec, 0); // [0, 0]
    });
  });

  group('ConnMeta.toFieldMap value typing', () {
    test('modbus fields carry the documented scalar types', () {
      final map = modbusMeta().toFieldMap();
      // Strings
      expect(map['state']!.value, isA<String>());
      expect(map['lastError']!.value, isA<String>());
      expect(map['destIp']!.value, isA<String>());
      // ints
      expect(map['destPort']!.value, isA<int>());
      expect(map['sourcePort']!.value, isA<int>());
      expect(map['unitId']!.value, isA<int>());
      expect(map['reconnectCount']!.value, isA<int>());
      expect(map['pollIntervalMs']!.value, isA<int>());
      // doubles
      expect(map['requestsPerSec']!.value, isA<double>());
      expect(map['uptimeSec']!.value, isA<double>());
      // bool
      expect(map['connected']!.value, isA<bool>());
      // Modbus does not expose OPC-UA-only fields.
      expect(map.containsKey('endpoint'), isFalse);
      expect(map.containsKey('channelState'), isFalse);
    });

    test('opcua fields carry the documented scalar types', () {
      final map = opcuaMeta().toFieldMap();
      expect(map['endpoint']!.value, isA<String>());
      expect(map['channelState']!.value, isA<String>());
      expect(map['sessionState']!.value, isA<String>());
      expect(map['statusCode']!.value, isA<int>());
      expect(map['subscribedKeys']!.value, isA<int>());
      expect(map['lastDataAgeSec']!.value, isA<double>());
      expect(map['connected']!.value, isA<bool>());
      // OPC-UA does not expose Modbus-only fields.
      expect(map.containsKey('unitId'), isFalse);
      expect(map.containsKey('sourcePort'), isFalse);
      expect(map.containsKey('pollIntervalMs'), isFalse);
    });
  });

  group('ConnMetaRouter parse & dispatch', () {
    late FakeConnMetaSource src;
    late ConnMetaRouter router;

    setUp(() {
      src = FakeConnMetaSource('plc1', modbusMeta());
      router = ConnMetaRouter([src]);
    });

    tearDown(() => src.dispose());

    test('isMetaKey recognises the @conn namespace', () {
      expect(ConnMetaRouter.isMetaKey('@conn/plc1/state'), isTrue);
      expect(ConnMetaRouter.isMetaKey('@conn'), isTrue);
      expect(ConnMetaRouter.isMetaKey('plainKey'), isFalse);
      expect(ConnMetaRouter.isMetaKey('\$var/x'), isFalse);
    });

    test('valid key resolves to the correct typed field', () {
      final dv = router.read('@conn/plc1/destPort');
      expect(dv.value, 502);
      final connected = router.read('@conn/plc1/connected');
      expect(connected.value, true);
    });

    test('unknown alias throws naming known aliases', () {
      expect(
        () => router.read('@conn/nope/state'),
        throwsA(isA<StateManException>().having((e) => e.message, 'message',
            allOf(contains('nope'), contains('plc1')))),
      );
    });

    test('unknown field throws naming the valid fields', () {
      expect(
        () => router.read('@conn/plc1/bogus'),
        throwsA(isA<StateManException>().having(
            (e) => e.message,
            'message',
            allOf(
                contains('bogus'), contains('state'), contains('sourcePort')))),
      );
    });

    test('wrong arity throws a format error', () {
      expect(
          () => router.read('@conn/plc1'), throwsA(isA<StateManException>()));
      expect(() => router.read('@conn/plc1/state/extra'),
          throwsA(isA<StateManException>()));
      expect(() => router.read('@conn'), throwsA(isA<StateManException>()));
    });

    test('metaKeys lists every valid field for the alias', () {
      final keys = router.metaKeys;
      expect(keys, contains('@conn/plc1/state'));
      expect(keys, contains('@conn/plc1/sourcePort'));
      expect(keys, contains('@conn/plc1/pollIntervalMs'));
      expect(keys.length, kConnMetaModbusFields.length);
    });
  });

  group('ConnMetaRouter.subscribe', () {
    test(
        'emits current value, then on state change and periodic tick, '
        'and cancels cleanly', () async {
      final src = FakeConnMetaSource('plc1', modbusMeta(requestsPerSec: 1));
      // Short tick so the periodic path is exercised without a real 1s wait.
      final router =
          ConnMetaRouter([src], tickInterval: const Duration(milliseconds: 30));

      final seen = <double>[];
      final sub = router
          .subscribe('@conn/plc1/requestsPerSec')
          .listen((dv) => seen.add((dv.value as num).toDouble()));

      // startWith → first value delivered on a microtask.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(seen, [1]);

      // Simulated connection-state change re-reads the (updated) snapshot.
      src.current = modbusMeta(requestsPerSec: 2);
      src.emitChange();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(seen.last, 2);

      // Periodic tick re-reads again after another value change.
      src.current = modbusMeta(requestsPerSec: 3);
      await Future<void>.delayed(const Duration(milliseconds: 45));
      expect(seen.last, 3);

      final countAtCancel = seen.length;
      await sub.cancel();
      src.dispose();

      // After cancel the periodic timer is gone — no further emissions.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(seen.length, countAtCancel);
    });

    test('subscribe to an unknown field errors eagerly', () {
      final src = FakeConnMetaSource('plc1', modbusMeta());
      final router = ConnMetaRouter([src]);
      expect(() => router.subscribe('@conn/plc1/bogus'),
          throwsA(isA<StateManException>()));
      src.dispose();
    });
  });

  group('ConnMetaRouter.subscribeAll', () {
    test(
        'emits the whole field map from one subscription and errors on an '
        'unknown alias', () async {
      final source = FakeConnMetaSource('mb1', modbusMeta());
      final router = ConnMetaRouter([source],
          tickInterval: const Duration(milliseconds: 10));

      final first = await router.subscribeAll('mb1').first;
      expect(first.keys, containsAll(kConnMetaModbusFields));
      expect(first['unitId']!.value, 1);

      expect(
          () => router.subscribeAll('nope'), throwsA(isA<StateManException>()));
      source.dispose();
    });

    test('aliases lists every source with its protocol', () {
      final router = ConnMetaRouter([
        FakeConnMetaSource('mb1', modbusMeta()),
        FakeConnMetaSource('plc1', opcuaMeta()),
      ]);
      expect(
        router.aliases,
        containsAll([
          (alias: 'mb1', isModbus: true),
          (alias: 'plc1', isModbus: false),
        ]),
      );
    });
  });

  group('StateMan integration', () {
    late StateMan stateMan;

    setUp(() async {
      // Enabled Modbus server that will never actually connect (port 1) —
      // the meta-keys resolve from config/getters without a live socket.
      final cfg = ModbusConfig(
        host: '127.0.0.1',
        port: 1,
        serverAlias: 'mb1',
        enabled: true,
        pollGroups: [ModbusPollGroupConfig(name: 'default', intervalMs: 750)],
      );
      final km = KeyMappings(nodes: {});
      stateMan = await StateMan.create(
        config: StateManConfig(opcua: [], modbus: [cfg]),
        keyMappings: km,
        deviceClients: buildModbusDeviceClients([cfg], km),
      );
    });

    tearDown(() async => stateMan.close());

    test(
        'an unnamed server gets a stable synthetic host:port identity — '
        'the SVN site config has every serverAlias null, and null is a '
        'first-class alias everywhere else in StateMan', () async {
      final cfg = ModbusConfig(
        host: '10.0.0.9',
        port: 502,
        serverAlias: null,
        enabled: true,
        pollGroups: [ModbusPollGroupConfig(name: 'default', intervalMs: 500)],
      );
      final km = KeyMappings(nodes: {});
      final sm = await StateMan.create(
        config: StateManConfig(opcua: [], modbus: [cfg]),
        keyMappings: km,
        deviceClients: buildModbusDeviceClients([cfg], km),
      );
      try {
        expect(sm.keys, contains('@conn/10.0.0.9:502/state'));
        expect(sm.connMetaAliases,
            contains((alias: '10.0.0.9:502', isModbus: true)));
        final ip = await sm.read('@conn/10.0.0.9:502/destIp');
        expect(ip.value, '10.0.0.9');
      } finally {
        await sm.close();
      }
    });

    test('keys() appends synthetic meta-keys for enabled servers', () {
      final keys = stateMan.keys;
      expect(keys, contains('@conn/mb1/state'));
      expect(keys, contains('@conn/mb1/connected'));
      expect(keys, contains('@conn/mb1/sourcePort'));
      expect(keys, contains('@conn/mb1/pollIntervalMs'));
      // Modbus meta-keys must not carry OPC-UA-only fields.
      expect(keys, isNot(contains('@conn/mb1/endpoint')));
    });

    test('read() returns a current snapshot for a meta-key', () async {
      final connected = await stateMan.read('@conn/mb1/connected');
      expect(connected.value, isFalse); // never connected
      final poll = await stateMan.read('@conn/mb1/pollIntervalMs');
      expect(poll.value, 750); // min configured poll-group interval
      final ip = await stateMan.read('@conn/mb1/destIp');
      expect(ip.value, '127.0.0.1');
    });

    test('write() to a meta-key throws a read-only error', () async {
      await expectLater(
        stateMan.write('@conn/mb1/state', DynamicValue(value: 'x')),
        throwsA(isA<StateManException>()
            .having((e) => e.message, 'message', contains('read-only'))),
      );
    });

    test('read() of an unknown field throws naming valid fields', () async {
      await expectLater(
        stateMan.read('@conn/mb1/bogus'),
        throwsA(isA<StateManException>()
            .having((e) => e.message, 'message', contains('valid fields'))),
      );
    });
  });
}
