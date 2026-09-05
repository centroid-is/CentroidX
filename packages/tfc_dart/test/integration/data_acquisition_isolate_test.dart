import 'dart:async';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:tfc_dart/core/data_acquisition_isolate.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/state_man.dart';

import 'docker_compose.dart';

// The isolate body used to live in `bin/`, so this file carried a local
// `TestIsolateConfig` copy and a comment claiming the real one could not be
// imported ("it has a main() conflict"). The body now lives in
// `lib/core/data_acquisition_isolate.dart` and is imported above; the copy is
// gone. The retry/respawn harness below is still deliberately a local
// re-implementation — it drives a DB-only entry point so it can stop the
// database out from under it, which the real body (an OPC UA session and a
// collector) cannot be asked to do here.

void main() {
  test('the real isolate config and entry point are importable', () {
    // Guards the move: if the body ever slides back into `bin/`, this file
    // stops compiling instead of silently re-growing a divergent copy.
    final config = DataAcquisitionIsolateConfig(
      dbConfigJson: const {},
      keyMappingsJson: const {},
    );
    expect(config.enableStatsLogging, isFalse);
    expect(dataAcquisitionIsolateEntry, isA<Function>());
  });

  group('DataAcquisition Isolate Integration', () {
    setUpAll(() async {
      await stopDockerCompose();
      await startDockerCompose();
      await waitForDatabaseReady();
    });

    tearDownAll(() async {
      await stopDockerCompose();
    });

    test('isolate should retry DB connection on startup failure', () async {
      // Stop the database first
      await stopTimescaleDb();
      await Future.delayed(const Duration(seconds: 1));

      final dbConfig = getTestConfig();
      final serverConfig = OpcUAConfig()..endpoint = 'opc.tcp://localhost:4840';
      final keyMappings = KeyMappings(nodes: {});

      // Track isolate lifecycle
      var errorCount = 0;
      var isolateStarted = false;
      final errorPort = ReceivePort();
      final exitPort = ReceivePort();
      final messagePort = ReceivePort();

      errorPort.listen((message) {
        errorCount++;
        print('Isolate error #$errorCount: ${message[0]}');
      });

      exitPort.listen((_) {
        print('Isolate exited');
      });

      messagePort.listen((message) {
        if (message == 'started') {
          isolateStarted = true;
        }
      });

      // Spawn an isolate that will fail to connect to DB
      await Isolate.spawn(
        _testIsolateEntryWithRetry,
        _TestIsolateMessage(
          dbConfigJson: dbConfig.toJson(),
          serverJson: serverConfig.toJson(),
          keyMappingsJson: keyMappings.toJson(),
          sendPort: messagePort.sendPort,
        ),
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
      );

      // Wait a bit for retries to happen
      await Future.delayed(const Duration(seconds: 5));

      // Start the database
      await startTimescaleDb();
      await waitForDatabaseReady();

      // Wait for isolate to successfully start after DB recovery
      await Future.delayed(const Duration(seconds: 10));

      // Verify isolate eventually started
      expect(isolateStarted, isTrue,
          reason: 'Isolate should have started after DB became available');

      // Cleanup
      errorPort.close();
      exitPort.close();
      messagePort.close();
    }, timeout: Timeout(Duration(seconds: 60)));

    test('isolate respawn on crash', () async {
      final dbConfig = getTestConfig();
      final serverConfig = OpcUAConfig()..endpoint = 'opc.tcp://localhost:4840';
      final keyMappings = KeyMappings(nodes: {});

      var spawnCount = 0;
      final spawnCountPort = ReceivePort();

      spawnCountPort.listen((message) {
        if (message == 'spawned') {
          spawnCount++;
          print('Isolate spawn count: $spawnCount');
        }
      });

      // Use our respawn wrapper
      await _spawnWithRespawn(
        dbConfigJson: dbConfig.toJson(),
        serverJson: serverConfig.toJson(),
        keyMappingsJson: keyMappings.toJson(),
        spawnPort: spawnCountPort.sendPort,
        crashAfterStart: true, // Tell isolate to crash after starting
      );

      // Wait for initial spawn + crash + respawn
      await Future.delayed(const Duration(seconds: 8));

      // Should have spawned at least twice (initial + respawn after crash)
      expect(spawnCount, greaterThanOrEqualTo(2),
          reason: 'Isolate should have been respawned after crash');

      spawnCountPort.close();
    }, timeout: Timeout(Duration(seconds: 30)));
  });
}

class _TestIsolateMessage {
  final Map<String, dynamic> dbConfigJson;
  final Map<String, dynamic> serverJson;
  final Map<String, dynamic> keyMappingsJson;
  final SendPort sendPort;
  final bool crashAfterStart;

  _TestIsolateMessage({
    required this.dbConfigJson,
    required this.serverJson,
    required this.keyMappingsJson,
    required this.sendPort,
    this.crashAfterStart = false,
  });
}

/// Test isolate entry point that mimics dataAcquisitionIsolateEntry with retry logic
@pragma('vm:entry-point')
Future<void> _testIsolateEntryWithRetry(_TestIsolateMessage message) async {
  final dbConfig = DatabaseConfig.fromJson(message.dbConfigJson);

  var delay = const Duration(seconds: 2);
  const maxDelay = Duration(seconds: 30);
  const maxAttempts = 10;

  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      // Try to create database connection (ignore: unused_local_variable)
      // ignore: unused_local_variable
      final db = Database(await AppDatabase.create(dbConfig));

      // Signal success
      message.sendPort.send('started');

      // Keep alive (briefly if crashing)
      if (message.crashAfterStart) {
        // Wait a moment then crash OUTSIDE the try-catch
        await Future.delayed(const Duration(milliseconds: 100));
        break; // Exit retry loop, then crash below
      }

      await Completer<void>().future;
      return;
    } catch (e) {
      if (attempt == maxAttempts) {
        rethrow;
      }
      print('Attempt $attempt failed: $e');
      await Future.delayed(delay);
      delay = delay * 2;
      if (delay > maxDelay) delay = maxDelay;
    }
  }

  // Crash outside try-catch to trigger respawn
  if (message.crashAfterStart) {
    throw Exception('Intentional crash for testing respawn');
  }
}

/// Spawn with respawn logic for testing
Future<void> _spawnWithRespawn({
  required Map<String, dynamic> dbConfigJson,
  required Map<String, dynamic> serverJson,
  required Map<String, dynamic> keyMappingsJson,
  required SendPort spawnPort,
  bool crashAfterStart = false,
}) async {
  var restartDelay = const Duration(seconds: 2);
  const maxDelay = Duration(seconds: 30);

  Future<void> spawn() async {
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();

    void scheduleRespawn(String reason) {
      errorPort.close();
      exitPort.close();
      print('Scheduling respawn in ${restartDelay.inSeconds}s ($reason)');
      Future.delayed(restartDelay, () {
        restartDelay = restartDelay * 2;
        if (restartDelay > maxDelay) restartDelay = maxDelay;
        spawn();
      });
    }

    errorPort.listen((message) {
      print('Isolate error: ${message[0]}');
      scheduleRespawn('error');
    });

    exitPort.listen((_) {
      print('Isolate exited');
      scheduleRespawn('exit');
    });

    spawnPort.send('spawned');

    await Isolate.spawn(
      _testIsolateEntryWithRetry,
      _TestIsolateMessage(
        dbConfigJson: dbConfigJson,
        serverJson: serverJson,
        keyMappingsJson: keyMappingsJson,
        sendPort: ReceivePort().sendPort, // Dummy port
        crashAfterStart: crashAfterStart,
      ),
      onError: errorPort.sendPort,
      onExit: exitPort.sendPort,
    );

    restartDelay = const Duration(seconds: 2);
  }

  await spawn();
}
