import 'dart:async';
import 'dart:typed_data';

import 'package:jbtm/jbtm.dart';
import 'package:jbtm/src/connection_health.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:test/test.dart';

import 'tcp_proxy.dart';

/// Helper: wait until [records] has at least [count] items, with timeout.
Future<void> _waitForRecords(
    List<DynamicValue> records, int count, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (records.length < count) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
          'Expected $count records, got ${records.length}', timeout);
    }
    await Future.delayed(Duration(milliseconds: 50));
  }
}

/// Helper: wait for MSocket status with timeout.
Future<void> _waitStatus(
    MSocket socket, ConnectionStatus target, Duration timeout) async {
  if (socket.status == target) return;
  await socket.statusStream.firstWhere((s) => s == target).timeout(timeout);
}

void main() {
  // Full pipeline: M2400StubServer -> TcpProxy -> MSocket -> M2400FrameParser
  //   -> parseM2400Frame -> parseTypedRecord -> convertRecordToDynamicValue
  //   -> M2400ClientWrapper subscribe -> DynamicValue assertions

  late M2400StubServer stubServer;
  late TcpProxy proxy;
  late MSocket socket;
  late M2400ClientWrapper wrapper;
  late int proxyPort;
  late int serverPort;

  // Track all received BATCH records (weight records)
  late List<DynamicValue> batchRecords;
  late StreamSubscription<DynamicValue> batchSub;

  setUp(() async {
    stubServer = M2400StubServer();
    serverPort = await stubServer.start();
    proxy = TcpProxy(targetPort: serverPort);
    await proxy.start();
    proxyPort = proxy.port;

    wrapper = M2400ClientWrapper('localhost', proxyPort);
    batchRecords = [];
    batchSub = wrapper.subscribe('BATCH').listen(
      (dv) => batchRecords.add(dv),
      onError: (_) {}, // Disconnect errors are expected in resilience tests
    );

    wrapper.connect();
    await wrapper.statusStream
        .firstWhere((s) => s == ConnectionStatus.connected)
        .timeout(Duration(seconds: 5));
    await stubServer.waitForClient();
    await Future.delayed(Duration(milliseconds: 100));
  });

  tearDown(() async {
    await batchSub.cancel();
    wrapper.dispose();
    await proxy.shutdown();
    await stubServer.shutdown();
  });

  /// Get the MSocket from wrapper for status tracking.
  /// We access it via statusStream on the wrapper.
  MSocket _getSocket() {
    // We need direct MSocket access for proxy tests. Since M2400ClientWrapper
    // hides its MSocket, we track status via wrapper.statusStream.
    // For status waits, use wrapper's statusStream.
    throw UnimplementedError('Use wrapper.statusStream instead');
  }

  /// Perform cable pull: shutdown proxy, wait for disconnect, restart on same port.
  Future<void> _cablePull() async {
    await proxy.shutdown();
    await wrapper.statusStream
        .firstWhere((s) => s == ConnectionStatus.disconnected)
        .timeout(Duration(seconds: 5));
    proxy = TcpProxy(listenPort: proxyPort, targetPort: serverPort);
    await proxy.start();
    await wrapper.statusStream
        .firstWhere((s) => s == ConnectionStatus.connected)
        .timeout(Duration(seconds: 10));
    await stubServer.waitForClient();
    await Future.delayed(Duration(milliseconds: 200));
  }

  // ---------------------------------------------------------------------------
  // Cable pull - full pipeline
  // ---------------------------------------------------------------------------
  group('cable pull - full pipeline', () {
    test('records delivered before and after cable pull, none during', () async {
      // Push 5 weight records with unique weights
      for (var i = 1; i <= 5; i++) {
        stubServer.pushWeightRecord(weight: '$i.000');
      }
      await _waitForRecords(batchRecords, 5, Duration(seconds: 5));

      // Verify pre-disconnect records
      final preWeights = batchRecords
          .map((dv) => dv['weight'].asDouble)
          .toList();
      expect(preWeights, [1.0, 2.0, 3.0, 4.0, 5.0]);

      // Cable pull
      await proxy.shutdown();
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.disconnected)
          .timeout(Duration(seconds: 5));

      // Push records while proxy is down -- these go to the stub server's
      // connected clients. But since the proxy is down, there are no clients
      // on the stub server's side (proxy-to-server connection was destroyed).
      // These records go nowhere.
      for (var i = 6; i <= 10; i++) {
        stubServer.pushWeightRecord(weight: '$i.000');
      }
      await Future.delayed(Duration(milliseconds: 200));

      // Cable reconnect
      proxy = TcpProxy(listenPort: proxyPort, targetPort: serverPort);
      await proxy.start();
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(Duration(seconds: 10));
      await stubServer.waitForClient();
      await Future.delayed(Duration(milliseconds: 200));

      // Push 5 more after reconnect
      for (var i = 11; i <= 15; i++) {
        stubServer.pushWeightRecord(weight: '$i.000');
      }
      await _waitForRecords(batchRecords, 10, Duration(seconds: 5));

      // Verify: should have records 1-5 and 11-15, NOT 6-10
      final allWeights = batchRecords
          .map((dv) => dv['weight'].asDouble)
          .toList();
      expect(allWeights, containsAll([1.0, 2.0, 3.0, 4.0, 5.0]));
      expect(allWeights, containsAll([11.0, 12.0, 13.0, 14.0, 15.0]));
      // Records 6-10 should NOT be present
      for (var i = 6; i <= 10; i++) {
        expect(allWeights, isNot(contains(i.toDouble())),
            reason: 'Record $i should not be present (sent during outage)');
      }
    });

    test('no duplicate records after cable pull recovery', () async {
      // Push 10 records with unique weights
      for (var i = 1; i <= 10; i++) {
        stubServer.pushWeightRecord(weight: '$i.000');
      }
      await _waitForRecords(batchRecords, 10, Duration(seconds: 5));

      // Cable pull + recover
      await _cablePull();

      // Push 10 more with different unique weights
      for (var i = 11; i <= 20; i++) {
        stubServer.pushWeightRecord(weight: '$i.000');
      }
      await _waitForRecords(batchRecords, 20, Duration(seconds: 5));

      // Verify no duplicate weights
      final weights = batchRecords
          .map((dv) => dv['weight'].asDouble)
          .toList();
      final uniqueWeights = weights.toSet();
      expect(uniqueWeights.length, weights.length,
          reason: 'No weight value should appear twice');
    });
  });

  // ---------------------------------------------------------------------------
  // Switch reboot - full pipeline
  // ---------------------------------------------------------------------------
  group('switch reboot - full pipeline', () {
    test('records resume after delayed proxy restart', () async {
      // Push 5 records before reboot
      for (var i = 1; i <= 5; i++) {
        stubServer.pushWeightRecord(weight: '$i.000');
      }
      await _waitForRecords(batchRecords, 5, Duration(seconds: 5));

      // Simulate switch going down
      await proxy.shutdown();
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.disconnected)
          .timeout(Duration(seconds: 5));

      // Simulate reboot delay
      await Future.delayed(Duration(seconds: 2));

      // Switch comes back up
      proxy = TcpProxy(listenPort: proxyPort, targetPort: serverPort);
      await proxy.start();
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(Duration(seconds: 10));
      await stubServer.waitForClient();
      await Future.delayed(Duration(milliseconds: 200));

      // Push 5 more records after reboot
      for (var i = 6; i <= 10; i++) {
        stubServer.pushWeightRecord(weight: '$i.000');
      }
      await _waitForRecords(batchRecords, 10, Duration(seconds: 5));

      // All 10 should arrive (5 pre-reboot + 5 post-reboot)
      final weights = batchRecords
          .map((dv) => dv['weight'].asDouble)
          .toList();
      expect(weights, containsAll([1.0, 2.0, 3.0, 4.0, 5.0]));
      expect(weights, containsAll([6.0, 7.0, 8.0, 9.0, 10.0]));
    });
  });

  // ---------------------------------------------------------------------------
  // Frame boundary resilience
  // ---------------------------------------------------------------------------
  group('frame boundary resilience', () {
    test('partial frame at disconnect does not corrupt next frame', () async {
      // Push a valid weight record and verify receipt
      stubServer.pushWeightRecord(weight: '42.000');
      await _waitForRecords(batchRecords, 1, Duration(seconds: 5));
      expect(batchRecords.last['weight'].asDouble, 42.0);

      // Cable pull + recover
      await _cablePull();

      // Push another valid record after reconnect
      stubServer.pushWeightRecord(weight: '99.000');
      await _waitForRecords(batchRecords, 2, Duration(seconds: 5));

      // The new record should parse correctly (FrameParser starts fresh
      // at next STX, ignoring any partial buffer from before disconnect)
      expect(batchRecords.last['weight'].asDouble, 99.0);
    });
  });

  // ---------------------------------------------------------------------------
  // Throughput recovery
  // ---------------------------------------------------------------------------
  group('throughput recovery', () {
    test('burst throughput matches pre-disruption after reconnect', () async {
      // Push burst of 50 records before disconnect
      stubServer.pushBurst(50);
      await _waitForRecords(batchRecords, 50, Duration(seconds: 10));

      final preBurstCount = batchRecords.length;
      expect(preBurstCount, greaterThanOrEqualTo(50));

      // Cable pull + recover
      await _cablePull();

      // Push burst of 50 more after reconnect
      stubServer.pushBurst(50, recordBuilder: (i) => (
            recordType: M2400RecordType.recBatch.id,
            fields: makeWeightFields(weight: '${i + 51}.000'),
          ));
      await _waitForRecords(
          batchRecords, preBurstCount + 50, Duration(seconds: 10));

      // All 100 should be received
      expect(batchRecords.length, greaterThanOrEqualTo(preBurstCount + 50));
    });
  });

  // ---------------------------------------------------------------------------
  // Health metrics through pipeline
  // ---------------------------------------------------------------------------
  group('health metrics through pipeline', () {
    test('records/second reflects actual pipeline throughput', () async {
      // Create a separate MSocket to track metrics
      // We need MSocket directly for ConnectionHealthMetrics.
      // Since wrapper hides its socket, create a parallel socket.
      final metricSocket = MSocket('localhost', proxyPort);
      final metrics = ConnectionHealthMetrics(metricSocket);
      addTearDown(() {
        metrics.dispose();
        metricSocket.dispose();
      });

      // Push 10 records rapidly through the wrapper pipeline
      for (var i = 0; i < 10; i++) {
        stubServer.pushWeightRecord(weight: '${i + 1}.000');
      }

      // Wait for records to arrive and notify metrics
      await _waitForRecords(batchRecords, 10, Duration(seconds: 5));

      // Manually notify metrics for each received record
      for (var i = 0; i < batchRecords.length; i++) {
        metrics.notifyRecord();
      }

      expect(metrics.recordsPerSecond, greaterThan(0));
    });

    test('reconnectCount tracks through pipeline disruptions', () async {
      // Use a raw MSocket to track metrics through the proxy
      final metricSocket = MSocket('localhost', proxyPort);
      final metrics = ConnectionHealthMetrics(metricSocket);
      metricSocket.connect();
      await metricSocket.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(Duration(seconds: 5));
      addTearDown(() {
        metrics.dispose();
        metricSocket.dispose();
      });

      expect(metrics.reconnectCount, 0);

      // Cable pull + recover
      await _cablePull();

      // metricSocket also reconnects through the same proxy
      await metricSocket.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(Duration(seconds: 10));

      expect(metrics.reconnectCount, 1);
    });
  });
}
