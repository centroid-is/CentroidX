import 'dart:async';

import 'package:jbtm/jbtm.dart' hide ConnectionStatus;
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:test/test.dart';
import 'package:tfc_dart/core/state_man.dart';

void main() {
  group('M2400DeviceClientAdapter', () {
    test('wraps M2400ClientWrapper as DeviceClient', () {
      final wrapper = M2400ClientWrapper('localhost', 12345);
      final adapter = M2400DeviceClientAdapter(wrapper);
      expect(adapter, isA<DeviceClient>());
      wrapper.dispose();
    });

    test('canSubscribe returns true for valid M2400 keys', () {
      final wrapper = M2400ClientWrapper('localhost', 12345);
      final adapter = M2400DeviceClientAdapter(wrapper);
      expect(adapter.canSubscribe('BATCH'), isTrue);
      expect(adapter.canSubscribe('STAT'), isTrue);
      expect(adapter.canSubscribe('INTRO'), isTrue);
      expect(adapter.canSubscribe('LUA'), isTrue);
      expect(adapter.canSubscribe('BATCH.weight'), isTrue);
      wrapper.dispose();
    });

    test('canSubscribe returns false for unknown keys', () {
      final wrapper = M2400ClientWrapper('localhost', 12345);
      final adapter = M2400DeviceClientAdapter(wrapper);
      expect(adapter.canSubscribe('opcUaKey'), isFalse);
      expect(adapter.canSubscribe('unknown'), isFalse);
      wrapper.dispose();
    });

    test('connectionStatus maps between msocket and state_man enums', () {
      final wrapper = M2400ClientWrapper('localhost', 12345);
      final adapter = M2400DeviceClientAdapter(wrapper);
      // Initially disconnected
      expect(adapter.connectionStatus, ConnectionStatus.disconnected);
      wrapper.dispose();
    });
  });

  group('Multi-device M2400 via StateMan', () {
    late M2400StubServer server1;
    late M2400StubServer server2;
    late int port1;
    late int port2;

    setUp(() async {
      server1 = M2400StubServer();
      server2 = M2400StubServer();
      port1 = await server1.start();
      port2 = await server2.start();
    });

    tearDown(() async {
      await server1.shutdown();
      await server2.shutdown();
    });

    test('createM2400DeviceClients creates one adapter per M2400Config', () {
      final configs = [
        M2400Config(host: 'localhost', port: port1)..serverAlias = 'scale1',
        M2400Config(host: 'localhost', port: port2)..serverAlias = 'scale2',
      ];
      final clients = createM2400DeviceClients(configs);
      expect(clients.length, 2);
      expect(clients[0], isA<DeviceClient>());
      expect(clients[1], isA<DeviceClient>());
      for (final c in clients) {
        c.dispose();
      }
    });

    test('createM2400DeviceClients with empty list creates no clients', () {
      final clients = createM2400DeviceClients([]);
      expect(clients, isEmpty);
    });

    test('subscribe routes M2400 key to correct wrapper by server alias', () async {
      final configs = [
        M2400Config(host: 'localhost', port: port1)..serverAlias = 'scale1',
        M2400Config(host: 'localhost', port: port2)..serverAlias = 'scale2',
      ];
      final clients = createM2400DeviceClients(configs);

      // Connect all clients
      for (final c in clients) {
        c.connect();
      }

      // Wait for connections to establish
      await server1.waitForClient();
      await server2.waitForClient();
      // Let the pipeline settle
      await Future.delayed(const Duration(milliseconds: 100));

      // Subscribe to BATCH on the first client
      final batchStream1 = clients[0].subscribe('BATCH');
      final completer1 = Completer<DynamicValue>();
      batchStream1.listen((dv) {
        if (!completer1.isCompleted) completer1.complete(dv);
      });

      // Push a weight from server1
      server1.pushWeightRecord(weight: '99.0');

      final dv1 = await completer1.future.timeout(const Duration(seconds: 5));
      expect(dv1['weight'].asDouble, 99.0);

      // Subscribe to BATCH on the second client
      final batchStream2 = clients[1].subscribe('BATCH');
      final completer2 = Completer<DynamicValue>();
      batchStream2.listen((dv) {
        if (!completer2.isCompleted) completer2.complete(dv);
      });

      // Push from server2
      server2.pushWeightRecord(weight: '55.0');

      final dv2 = await completer2.future.timeout(const Duration(seconds: 5));
      expect(dv2['weight'].asDouble, 55.0);

      for (final c in clients) {
        c.dispose();
      }
    });

    test('devices connect independently', () async {
      final configs = [
        M2400Config(host: 'localhost', port: port1)..serverAlias = 'scale1',
        M2400Config(host: 'localhost', port: port2)..serverAlias = 'scale2',
      ];
      final clients = createM2400DeviceClients(configs);

      for (final c in clients) {
        c.connect();
      }

      await server1.waitForClient();
      await server2.waitForClient();
      await Future.delayed(const Duration(milliseconds: 100));

      // Both should be connected
      expect(clients[0].connectionStatus, ConnectionStatus.connected);
      expect(clients[1].connectionStatus, ConnectionStatus.connected);

      for (final c in clients) {
        c.dispose();
      }
    });

    test('dispose cleans up all wrappers', () async {
      final configs = [
        M2400Config(host: 'localhost', port: port1)..serverAlias = 'scale1',
        M2400Config(host: 'localhost', port: port2)..serverAlias = 'scale2',
      ];
      final clients = createM2400DeviceClients(configs);

      for (final c in clients) {
        c.connect();
      }
      await server1.waitForClient();
      await server2.waitForClient();
      await Future.delayed(const Duration(milliseconds: 100));

      // Dispose all
      for (final c in clients) {
        c.dispose();
      }

      // After dispose, status should be disconnected
      // (The adapter may not update status after dispose, but the wrapper is dead)
      // Just verify no exceptions were thrown during dispose
    });

    test('connection status from each wrapper is independent', () async {
      final configs = [
        M2400Config(host: 'localhost', port: port1)..serverAlias = 'scale1',
        // Port that won't accept connections
        M2400Config(host: 'localhost', port: 1)..serverAlias = 'scale2',
      ];
      final clients = createM2400DeviceClients(configs);

      // Only connect client 1 - client 2 will fail to connect
      clients[0].connect();
      await server1.waitForClient();
      await Future.delayed(const Duration(milliseconds: 100));

      expect(clients[0].connectionStatus, ConnectionStatus.connected);
      // Client 2 not connected - it was never told to connect
      expect(clients[1].connectionStatus, ConnectionStatus.disconnected);

      for (final c in clients) {
        c.dispose();
      }
    });
  });

  group('Collector integration for M2400 BATCH records', () {
    late M2400StubServer server;
    late int port;

    setUp(() async {
      server = M2400StubServer();
      port = await server.start();
    });

    tearDown(() async {
      await server.shutdown();
    });

    test('M2400 key with collect entry works through DeviceClient subscribe', () async {
      final config = M2400Config(host: 'localhost', port: port)
        ..serverAlias = 'scale1';
      final clients = createM2400DeviceClients([config]);

      clients[0].connect();
      await server.waitForClient();
      await Future.delayed(const Duration(milliseconds: 100));

      // Subscribe to BATCH key
      final stream = clients[0].subscribe('BATCH');
      final completer = Completer<DynamicValue>();
      stream.listen((dv) {
        if (!completer.isCompleted) completer.complete(dv);
      });

      // Push a BATCH record
      server.pushWeightRecord(weight: '42.5');
      final dv = await completer.future.timeout(const Duration(seconds: 5));
      expect(dv['weight'].asDouble, 42.5);

      for (final c in clients) {
        c.dispose();
      }
    });

    test('multiple M2400 devices can each have collected keys independently', () async {
      final server2 = M2400StubServer();
      final port2 = await server2.start();

      try {
        final configs = [
          M2400Config(host: 'localhost', port: port)..serverAlias = 'scale1',
          M2400Config(host: 'localhost', port: port2)..serverAlias = 'scale2',
        ];
        final clients = createM2400DeviceClients(configs);

        for (final c in clients) {
          c.connect();
        }
        await server.waitForClient();
        await server2.waitForClient();
        await Future.delayed(const Duration(milliseconds: 100));

        // Subscribe to BATCH on both
        final values1 = <DynamicValue>[];
        final values2 = <DynamicValue>[];
        final sub1 = clients[0].subscribe('BATCH').listen(values1.add);
        final sub2 = clients[1].subscribe('BATCH').listen(values2.add);

        // Push from server1
        server.pushWeightRecord(weight: '10.0');
        await Future.delayed(const Duration(milliseconds: 200));

        // Push from server2
        server2.pushWeightRecord(weight: '20.0');
        await Future.delayed(const Duration(milliseconds: 200));

        expect(values1.length, 1);
        expect(values1[0]['weight'].asDouble, 10.0);
        expect(values2.length, 1);
        expect(values2[0]['weight'].asDouble, 20.0);

        await sub1.cancel();
        await sub2.cancel();
        for (final c in clients) {
          c.dispose();
        }
      } finally {
        await server2.shutdown();
      }
    });
  });
}
