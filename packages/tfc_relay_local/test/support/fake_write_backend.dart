/// An [AppDatabase] whose write path can be taken down, brought back up, and
/// made to fail with a specific SQLSTATE — copied from
/// `packages/tfc_dart/test/core/fake_write_backend.dart`, which is the model
/// this file credits. It lives in that package's `test/`, so it cannot be
/// imported from here and has to be re-created.
///
/// Two levers are added over the original, both for 8b-02's sink tests:
///
///  * [failingTables] — a per-table failure switch, so one table's batches
///    can fail while a neighbour's succeed.
///  * [health] — a hand-driven connection-health stream, wired through
///    `connectionHealthBroadcastForTest` (the setter exists at
///    `database_drift.dart` for exactly this), so a test can flip what
///    `Database.connectionState` reports without a server anywhere.
///
/// A caution the original's tests all live by and this file inherits:
/// `Database`'s **constructor starts its 500 ms flush timer** before the
/// caller can say a word, so every test that wraps this backend in a
/// `Database` must `close()` it in teardown or the timer outlives the case.
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';

class FakeWriteBackend extends AppDatabase {
  FakeWriteBackend()
      : super.forTest(
            DatabaseConfig(), NativeDatabase.memory(logStatements: false)) {
    connectionHealthBroadcastForTest = health.stream;
  }

  /// While true, every call fails the way an unreachable server does.
  bool down = false;

  /// If set, [tableInsertBatch] throws this instead of storing (used to stand
  /// in for a server that rejects the batch's *contents*).
  Object? rejectWith;

  /// Tables whose batches fail with a connection-shaped error even while the
  /// backend as a whole is up — the per-table failure switch.
  final Set<String> failingTables = <String>{};

  /// What [tableExists] answers. The original always said true; the
  /// null-first-sample path in `Database.insertTimeseriesData` is only
  /// reachable when the table does *not* exist yet.
  bool existsResult = true;

  /// How many times [tableExists] has been asked, which is how a test can
  /// see that an idempotent second `ensureTable` issued nothing new.
  int existsCalls = 0;

  /// The connection-health lever. `Database._initConnectionHealth` listens to
  /// this; add `false` to make `connectionState` report an outage.
  final StreamController<bool> health = StreamController<bool>.broadcast();

  /// Every row the backend was ever asked to store, in arrival order.
  final List<Map<String, dynamic>> stored = [];

  /// How many times [tableInsertBatch] has been called, successful or not.
  int insertAttempts = 0;

  @override
  Future<bool> tableExists(String tableName) async {
    existsCalls++;
    if (down) throw Exception('SocketException: Connection refused');
    return existsResult;
  }

  @override
  Future<int> tableInsertBatch(
      String tableName, List<Map<String, dynamic>> rows) async {
    insertAttempts++;
    if (down) throw Exception('SocketException: Connection refused');
    if (failingTables.contains(tableName)) {
      throw Exception('SocketException: Connection reset by peer');
    }
    final reject = rejectWith;
    if (reject != null) throw reject;
    stored.addAll(rows);
    return rows.length;
  }

  /// The `value` column of every stored row, as numbers.
  List<num> get storedValues =>
      stored.map((r) => r['value'] as num).toList(growable: false);
}
