import 'dart:async';

import 'package:logger/logger.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';

part 'database.g.dart';

/// File-level logger. These diagnostics used to go to stderr, which in a
/// windowed MSIX build with no console is discarded outright.
final Logger _log = Logger();

@Riverpod(keepAlive: true)
Future<Database?> database(Ref ref) async {
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
    // The database is unreachable and a retry loop is about to start that
    // reports nothing. This is the "trends are empty and nobody knows why"
    // line, and on stderr nobody ever saw it.
    _log.e('Error opening database: $e');
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
