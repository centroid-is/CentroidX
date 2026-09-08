import 'dart:io' as io;
import 'dart:async';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';

import '../core/gateway_config.dart';
import 'gateway.dart';

part 'database.g.dart';

@Riverpod(keepAlive: true)
Future<Database?> database(Ref ref) async {
  // The transport branch. A panel in gateway mode holds one WebSocket to the
  // backend, and the backend is the only process that touches TimescaleDB —
  // so this provider returns before reading the row, before spawning a pool
  // and before scheduling a probe. Everything downstream already treats null
  // as the normal no-database state (it is the Postgres-unreachable state in
  // direct mode), and 17-12 proved the access surface over the relay with
  // this provider null AND throwing.
  //
  // `ref.read`, deliberately, matching `state_man.dart:189-196`: this
  // provider is `keepAlive` and holds the station's Postgres pool, and
  // `server_config.dart` invalidates `gatewayConfigProvider` on every
  // transport save — a `ref.watch` here would tear the pool down under
  // widgets holding subscriptions each time an operator touches the gateway
  // URL field on a DIRECT station. Switching transport is restart-to-apply
  // (`gateway.dart:20-24`), and a rebuild of this provider (a database
  // settings save does that) re-reads the current transport anyway.
  //
  // The catch mirrors `readGatewayConfig`'s own policy: direct mode is the
  // default in every direction, so a device-local store that cannot be read
  // leaves the plant running exactly as it does today.
  GatewayConfig gateway;
  try {
    gateway = await ref.read(gatewayConfigProvider.future);
  } catch (_) {
    gateway = GatewayConfig.defaults;
  }
  if (gateway.isGateway) {
    return null;
  }

  final config = await DatabaseConfig.fromPrefs();
  if (config.postgres == null) {
    return null;
  }
  AppDatabase? appDb;
  try {
    appDb = await AppDatabase.spawn(config);
    final db = Database(appDb);
    await db.db.open();

    // Clean up when the provider is invalidated or disposed.
    // The pg pool's built-in keepalive handles reconnection after
    // transient outages — no provider-level recovery needed.
    ref.onDispose(() async {
      _retryTimer?.cancel();
      await db.dispose();
      await db.db.close();
    });

    return db;
  } catch (e) {
    // close() now properly kills the DriftIsolate via shutdownAll()
    await appDb?.close();
    io.stderr.writeln('Error opening database: $e');
    _scheduleRetry(ref, config);
    ref.onDispose(() {
      _retryTimer?.cancel();
    });
  }
  return null;
}

Timer? _retryTimer;

/// Schedule initial connection retry (DB was never reachable).
void _scheduleRetry(Ref ref, DatabaseConfig config) {
  _retryTimer?.cancel();
  _retryTimer = Timer(const Duration(seconds: 2), () async {
    try {
      await Database.probe(config);
    } catch (e) {
      _scheduleRetry(ref, config);
      return;
    }
    ref.invalidateSelf();
  });
}
