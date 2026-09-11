import 'dart:async';

import 'package:jbtm/jbtm.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:test/test.dart';

/// End-to-end integration tests for the M2400 pipeline:
///
/// M2400StubServer -> TCP -> MSocket -> M2400FrameParser -> parseM2400Frame
///   -> parseTypedRecord -> convertRecordToDynamicValue -> M2400ClientWrapper
///   -> subscribe stream -> DynamicValue assertions
///
/// Tests verify the full pipeline from wire bytes to typed DynamicValue streams,
/// including record type routing, replay semantics, dot-notation field access,
/// and reconnection resilience.
void main() {
  late M2400StubServer stub;
  late M2400ClientWrapper wrapper;

  setUp(() async {
    stub = M2400StubServer();
    final port = await stub.start();
    wrapper = M2400ClientWrapper('localhost', port);
    wrapper.connect();
    await stub.waitForClient();
    // Wait for connected status
    await wrapper.statusStream
        .firstWhere((s) => s == ConnectionStatus.connected)
        .timeout(const Duration(seconds: 5));
    // Small delay for pipeline readiness
    await Future.delayed(const Duration(milliseconds: 100));
  });

  tearDown(() async {
    wrapper.dispose();
    await stub.shutdown();
  });

  // ---------------------------------------------------------------------------
  // Core pipeline: stub pushes record -> subscriber receives DynamicValue
  // ---------------------------------------------------------------------------
  group('M2400 end-to-end pipeline', () {
    test('batch record flows from stub to BATCH subscriber with correct weight',
        () async {
      final completer = Completer<DynamicValue>();
      wrapper.subscribe('BATCH').listen((dv) {
        if (!completer.isCompleted) completer.complete(dv);
      });

      stub.pushWeightRecord(weight: '25.500');
      final dv = await completer.future.timeout(const Duration(seconds: 5));

      expect(dv, isNotNull);
      expect(dv.isObject, isTrue);
      expect(dv['weight'].asDouble, 25.5);
      expect(dv['unit'].asString, 'kg');
    });

    test('stat record flows from stub to STAT subscriber', () async {
      final completer = Completer<DynamicValue>();
      wrapper.subscribe('STAT').listen((dv) {
        if (!completer.isCompleted) completer.complete(dv);
      });

      stub.pushStatRecord(weight: '12.37', unit: 'kg');
      final dv = await completer.future.timeout(const Duration(seconds: 5));

      expect(dv, isNotNull);
      expect(dv.isObject, isTrue);
      expect(dv['weight'].asDouble, 12.37);
      expect(dv['unit'].asString, 'kg');
    });

    test('intro record flows from stub to INTRO subscriber', () async {
      // Stub server auto-sends INTRO on connect; subscribe should get replay
      final completer = Completer<DynamicValue>();
      wrapper.subscribe('INTRO').listen((dv) {
        if (!completer.isCompleted) completer.complete(dv);
      });

      final dv = await completer.future.timeout(const Duration(seconds: 5));

      expect(dv, isNotNull);
      expect(dv.isObject, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // Replay semantics
  // ---------------------------------------------------------------------------
  group('replay semantics', () {
    test('STAT replays last value to late subscriber', () async {
      // Push a stat record
      final first = Completer<DynamicValue>();
      wrapper.subscribe('STAT').listen((dv) {
        if (!first.isCompleted) first.complete(dv);
      });

      stub.pushStatRecord(weight: '9.99');
      await first.future.timeout(const Duration(seconds: 5));

      // Late subscriber should get replay of last STAT value
      final replay = Completer<DynamicValue>();
      wrapper.subscribe('STAT').listen((dv) {
        if (!replay.isCompleted) replay.complete(dv);
      });

      final replayDv = await replay.future.timeout(const Duration(seconds: 2));
      expect(replayDv, isNotNull);
      expect(replayDv['weight'].asDouble, 9.99);
    });

    test('BATCH does NOT replay to late subscriber (event-only)', () async {
      // Push a batch record
      final first = Completer<DynamicValue>();
      wrapper.subscribe('BATCH').listen((dv) {
        if (!first.isCompleted) first.complete(dv);
      });

      stub.pushWeightRecord(weight: '33.000');
      await first.future.timeout(const Duration(seconds: 5));

      // Late subscriber should NOT get replay
      final batchValues = <DynamicValue>[];
      wrapper.subscribe('BATCH').listen(batchValues.add);
      await Future.delayed(const Duration(milliseconds: 300));

      expect(batchValues, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Dot-notation field access
  // ---------------------------------------------------------------------------
  group('dot-notation field access', () {
    test('subscribe BATCH.weight extracts weight field', () async {
      final completer = Completer<DynamicValue>();
      wrapper.subscribe('BATCH.weight').listen((dv) {
        if (!completer.isCompleted) completer.complete(dv);
      });

      stub.pushWeightRecord(weight: '33.750');
      final dv = await completer.future.timeout(const Duration(seconds: 5));

      expect(dv, isNotNull);
      // Dot-notation returns the child DynamicValue, not the parent
      expect(dv.asDouble, 33.75);
    });

    test('subscribe STAT.unit extracts unit field', () async {
      final completer = Completer<DynamicValue>();
      wrapper.subscribe('STAT.unit').listen((dv) {
        if (!completer.isCompleted) completer.complete(dv);
      });

      stub.pushStatRecord(weight: '5.00', unit: 'lb');
      final dv = await completer.future.timeout(const Duration(seconds: 5));

      expect(dv, isNotNull);
      expect(dv.asString, 'lb');
    });
  });

  // ---------------------------------------------------------------------------
  // Type isolation
  // ---------------------------------------------------------------------------
  group('type isolation', () {
    test('BATCH subscriber ignores STAT records', () async {
      final batchValues = <DynamicValue>[];
      wrapper.subscribe('BATCH').listen(batchValues.add);

      // Push STAT records (should be ignored by BATCH subscriber)
      stub.pushStatRecord(weight: '1.0');
      stub.pushStatRecord(weight: '2.0');
      await Future.delayed(const Duration(milliseconds: 300));

      expect(batchValues, isEmpty);
    });

    test('multiple record types interleaved - each subscriber gets only theirs',
        () async {
      final batchValues = <DynamicValue>[];
      final statValues = <DynamicValue>[];

      wrapper.subscribe('BATCH').listen(batchValues.add);
      wrapper.subscribe('STAT').listen(statValues.add);

      // Interleave: STAT, BATCH, STAT, BATCH
      stub.pushStatRecord(weight: '10.0');
      stub.pushWeightRecord(weight: '20.0');
      stub.pushStatRecord(weight: '30.0');
      stub.pushWeightRecord(weight: '40.0');

      // Wait for processing
      await Future.delayed(const Duration(milliseconds: 500));

      expect(batchValues.length, equals(2));
      expect(statValues.length, greaterThanOrEqualTo(2));

      expect(batchValues[0]['weight'].asDouble, 20.0);
      expect(batchValues[1]['weight'].asDouble, 40.0);
    });
  });

  // ---------------------------------------------------------------------------
  // Reconnection resilience
  // ---------------------------------------------------------------------------
  group('reconnection', () {
    test('data resumes after disconnect and reconnect', () async {
      // Get first record to confirm pipeline works
      final first = Completer<DynamicValue>();
      wrapper.subscribe('BATCH').listen(
        (dv) {
          if (!first.isCompleted) first.complete(dv);
        },
        onError: (_) {}, // Disconnect errors expected
      );

      stub.pushWeightRecord(weight: '10.0');
      await first.future.timeout(const Duration(seconds: 5));

      // Disconnect all clients
      stub.disconnectAll();

      // Wait for disconnected status
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.disconnected)
          .timeout(const Duration(seconds: 5));

      // MSocket auto-reconnects; wait for the stub server to see the new client
      await stub.waitForClient();

      // Wait for connected status
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 10));

      // Small delay for pipeline re-establishment
      await Future.delayed(const Duration(milliseconds: 200));

      // Push another record -- should flow through the re-established pipeline
      final second = Completer<DynamicValue>();
      wrapper.subscribe('BATCH').listen(
        (dv) {
          if (!second.isCompleted) second.complete(dv);
        },
        onError: (_) {}, // Disconnect errors expected
      );

      stub.pushWeightRecord(weight: '20.0');
      final dv = await second.future.timeout(const Duration(seconds: 10));

      expect(dv, isNotNull);
      expect(dv['weight'].asDouble, 20.0);
    });

    test('status transitions through disconnect/reconnect cycle', () async {
      // Should already be connected from setUp
      expect(wrapper.status, ConnectionStatus.connected);

      // Disconnect
      stub.disconnectAll();
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.disconnected)
          .timeout(const Duration(seconds: 5));

      expect(wrapper.status, ConnectionStatus.disconnected);

      // Reconnect (auto-reconnect via MSocket)
      await stub.waitForClient();
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 10));

      expect(wrapper.status, ConnectionStatus.connected);
    });
  });
}
