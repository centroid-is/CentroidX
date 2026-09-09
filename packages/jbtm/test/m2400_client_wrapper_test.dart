import 'dart:async';

import 'package:jbtm/jbtm.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:test/test.dart';

void main() {
  late M2400StubServer server;
  late M2400ClientWrapper wrapper;

  setUp(() async {
    server = M2400StubServer();
    final port = await server.start();
    wrapper = M2400ClientWrapper('localhost', port);
  });

  tearDown(() async {
    wrapper.dispose();
    await server.shutdown();
  });

  // ---------------------------------------------------------------------------
  // Connection lifecycle
  // ---------------------------------------------------------------------------
  group('connection lifecycle', () {
    test('connect() transitions status to connecting then connected', () async {
      final statuses = <ConnectionStatus>[];
      wrapper.statusStream.listen(statuses.add);

      wrapper.connect();

      // Wait for connected
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));

      expect(statuses, contains(ConnectionStatus.connecting));
      expect(statuses, contains(ConnectionStatus.connected));
    });

    test('disconnect() transitions status to disconnected', () async {
      wrapper.connect();
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));

      wrapper.disconnect();

      // MSocket may go through its own state changes; ultimately disconnected
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.disconnected)
          .timeout(const Duration(seconds: 5));

      expect(wrapper.status, ConnectionStatus.disconnected);
    });

    test('status stream maps MSocket ConnectionStatus correctly', () async {
      // Initial status is disconnected (from MSocket's BehaviorSubject)
      expect(wrapper.status, ConnectionStatus.disconnected);

      wrapper.connect();
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));

      expect(wrapper.status, ConnectionStatus.connected);
    });
  });

  // ---------------------------------------------------------------------------
  // Stream routing -- type isolation
  // ---------------------------------------------------------------------------
  group('stream routing', () {
    test('subscribe BATCH returns Stream that emits DynamicValue on recBatch',
        () async {
      wrapper.connect();
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));
      await server.waitForClient();
      // Small delay for pipeline to be ready
      await Future.delayed(const Duration(milliseconds: 100));

      final gotBatch = Completer<DynamicValue>();
      wrapper.subscribe('BATCH').listen((dv) {
        if (!gotBatch.isCompleted) gotBatch.complete(dv);
      });

      server.pushWeightRecord(weight: '25.000');
      final dv = await gotBatch.future.timeout(const Duration(seconds: 5));

      expect(dv.isObject, isTrue);
      expect(dv['weight'].asDouble, 25.0);
    });

    test('subscribe STAT returns Stream that emits DynamicValue on recStat',
        () async {
      wrapper.connect();
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));
      await server.waitForClient();
      await Future.delayed(const Duration(milliseconds: 100));

      final gotStat = Completer<DynamicValue>();
      wrapper.subscribe('STAT').listen((dv) {
        if (!gotStat.isCompleted) gotStat.complete(dv);
      });

      server.pushStatRecord(weight: '9.99');
      final dv = await gotStat.future.timeout(const Duration(seconds: 5));

      expect(dv.isObject, isTrue);
      expect(dv['weight'].asDouble, 9.99);
    });

    test('subscribe BATCH does NOT emit when stub pushes recStat (type isolation)',
        () async {
      wrapper.connect();
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));
      await server.waitForClient();
      await Future.delayed(const Duration(milliseconds: 100));

      final batchValues = <DynamicValue>[];
      wrapper.subscribe('BATCH').listen(batchValues.add);

      // Push a STAT record (not BATCH)
      server.pushStatRecord(weight: '5.00');
      // Give time for any incorrect routing
      await Future.delayed(const Duration(milliseconds: 200));

      expect(batchValues, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Replay semantics -- BehaviorSubject for STAT/INTRO, event-only for BATCH/LUA
  // ---------------------------------------------------------------------------
  group('replay semantics', () {
    test('subscribe STAT replays last value to new subscriber', () async {
      wrapper.connect();
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));
      await server.waitForClient();
      await Future.delayed(const Duration(milliseconds: 100));

      // Push a stat record BEFORE subscribing
      server.pushStatRecord(weight: '7.77');
      // Wait for it to be processed by the pipeline
      await Future.delayed(const Duration(milliseconds: 200));

      // Now subscribe -- should get the replayed last value
      final gotReplay = Completer<DynamicValue>();
      wrapper.subscribe('STAT').listen((dv) {
        if (!gotReplay.isCompleted) gotReplay.complete(dv);
      });

      final dv = await gotReplay.future.timeout(const Duration(seconds: 5));
      expect(dv['weight'].asDouble, 7.77);
    });

    test('subscribe BATCH does NOT replay to new subscriber (event-only)',
        () async {
      wrapper.connect();
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));
      await server.waitForClient();
      await Future.delayed(const Duration(milliseconds: 100));

      // Push a batch record BEFORE subscribing
      server.pushWeightRecord(weight: '33.000');
      await Future.delayed(const Duration(milliseconds: 200));

      // Subscribe now -- should NOT get replay
      final batchValues = <DynamicValue>[];
      wrapper.subscribe('BATCH').listen(batchValues.add);
      await Future.delayed(const Duration(milliseconds: 200));

      expect(batchValues, isEmpty);
    });

    test('subscribe INTRO replays last value (device identity = current state)',
        () async {
      wrapper.connect();
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));
      await server.waitForClient();
      // The stub server auto-sends INTRO on connect, so let the pipeline process it
      await Future.delayed(const Duration(milliseconds: 300));

      // Subscribe after the auto-INTRO was sent
      final gotReplay = Completer<DynamicValue>();
      wrapper.subscribe('INTRO').listen((dv) {
        if (!gotReplay.isCompleted) gotReplay.complete(dv);
      });

      final dv = await gotReplay.future.timeout(const Duration(seconds: 5));
      expect(dv.isObject, isTrue);
    });

    test('subscribe LUA does NOT replay (event-only)', () async {
      wrapper.connect();
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));
      await server.waitForClient();
      await Future.delayed(const Duration(milliseconds: 100));

      // Push a LUA record BEFORE subscribing
      server.pushLuaRecord(extra: {'key': 'val'});
      await Future.delayed(const Duration(milliseconds: 200));

      // Subscribe now -- should NOT get replay
      final luaValues = <DynamicValue>[];
      wrapper.subscribe('LUA').listen(luaValues.add);
      await Future.delayed(const Duration(milliseconds: 200));

      expect(luaValues, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Dot-notation field access
  // ---------------------------------------------------------------------------
  group('dot-notation subscribe', () {
    test('subscribe BATCH.weight emits only the weight child DynamicValue',
        () async {
      wrapper.connect();
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));
      await server.waitForClient();
      await Future.delayed(const Duration(milliseconds: 100));

      final gotWeight = Completer<DynamicValue>();
      wrapper.subscribe('BATCH.weight').listen((dv) {
        if (!gotWeight.isCompleted) gotWeight.complete(dv);
      });

      server.pushWeightRecord(weight: '42.500');
      final dv = await gotWeight.future.timeout(const Duration(seconds: 5));

      expect(dv.asDouble, 42.5);
    });

    test('subscribe BATCH.unit emits only the unit child DynamicValue',
        () async {
      wrapper.connect();
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));
      await server.waitForClient();
      await Future.delayed(const Duration(milliseconds: 100));

      final gotUnit = Completer<DynamicValue>();
      wrapper.subscribe('BATCH.unit').listen((dv) {
        if (!gotUnit.isCompleted) gotUnit.complete(dv);
      });

      server.pushWeightRecord(unit: 'lb');
      final dv = await gotUnit.future.timeout(const Duration(seconds: 5));

      expect(dv.asString, 'lb');
    });
  });

  // ---------------------------------------------------------------------------
  // Connection error propagation
  // ---------------------------------------------------------------------------
  group('connection error propagation', () {
    test('subscribe stream emits error when server goes down', () async {
      wrapper.connect();
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));
      await server.waitForClient();
      await Future.delayed(const Duration(milliseconds: 100));

      // Subscribe and get at least one value
      final values = <DynamicValue>[];
      Object? streamError;
      wrapper.subscribe('STAT').listen(
        values.add,
        onError: (e) => streamError = e,
      );

      server.pushStatRecord(weight: '1.23');
      await Future.delayed(const Duration(milliseconds: 200));
      expect(values, isNotEmpty);
      expect(values.last['weight'].asDouble, 1.23);

      // Kill the server — subscribers should see an error
      await server.shutdown();
      await Future.delayed(const Duration(milliseconds: 500));

      expect(streamError, isNotNull);
    });

    test('BATCH (event-only) stream also receives disconnect error', () async {
      wrapper.connect();
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));
      await server.waitForClient();
      await Future.delayed(const Duration(milliseconds: 100));

      Object? streamError;
      wrapper.subscribe('BATCH').listen(
        (_) {},
        onError: (e) => streamError = e,
      );

      // Get at least one value to confirm subscription works
      server.pushWeightRecord(weight: '1.00');
      await Future.delayed(const Duration(milliseconds: 200));

      // Kill the server
      await server.shutdown();
      await Future.delayed(const Duration(milliseconds: 500));

      expect(streamError, isNotNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Error handling
  // ---------------------------------------------------------------------------
  group('error handling', () {
    test('subscribe with unknown key throws ArgumentError', () {
      expect(
        () => wrapper.subscribe('UNKNOWN'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('subscribe with unknown dot-notation root key throws ArgumentError',
        () {
      expect(
        () => wrapper.subscribe('UNKNOWN.field'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Stream sharing
  // ---------------------------------------------------------------------------
  group('stream sharing', () {
    test('multiple subscribers to same key share the same stream', () async {
      wrapper.connect();
      await wrapper.statusStream
          .firstWhere((s) => s == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));
      await server.waitForClient();
      await Future.delayed(const Duration(milliseconds: 100));

      final got1 = Completer<DynamicValue>();
      final got2 = Completer<DynamicValue>();

      wrapper.subscribe('BATCH').listen((dv) {
        if (!got1.isCompleted) got1.complete(dv);
      });
      wrapper.subscribe('BATCH').listen((dv) {
        if (!got2.isCompleted) got2.complete(dv);
      });

      server.pushWeightRecord(weight: '11.111');

      final dv1 = await got1.future.timeout(const Duration(seconds: 5));
      final dv2 = await got2.future.timeout(const Duration(seconds: 5));

      expect(dv1['weight'].asDouble, 11.111);
      expect(dv2['weight'].asDouble, 11.111);
    });
  });
}
