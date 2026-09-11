/// A [TimeseriesSink] with levers, so 8b-03's runner tests need no database.
///
/// In `test/support/` and not in `lib/`, for the same reason the
/// `StateManHarness` levers are (`freeze_test.dart`'s harness sweep): a
/// production class with a "go down" lever on it is a production class a
/// session can reach.
library;

import 'dart:async';

import 'package:tfc_dart/tfc_dart.dart' show RetentionPolicy;
import 'package:tfc_relay_local/tfc_relay_local.dart';

/// One recorded `insert`, in arrival order.
final class FakeSinkRow {
  FakeSinkRow(this.table, this.time, this.value);
  final String table;
  final DateTime time;
  final Object? value;
}

final class FakeSink implements TimeseriesSink {
  /// Every accepted insert, in arrival order.
  final List<FakeSinkRow> accepted = <FakeSinkRow>[];

  /// Inserts taken while down: buffered, not accepted.
  final List<FakeSinkRow> buffered = <FakeSinkRow>[];

  /// What [ensureTable] was asked for, last call per table. Idempotence is
  /// the caller's claim to verify, so the count is kept too.
  final Map<String, RetentionPolicy?> ensuredTables =
      <String, RetentionPolicy?>{};
  int ensureCalls = 0;

  /// Tables whose inserts fail — counted as drops, never thrown, because
  /// the seam's `insert` is documented non-throwing and the fake must hold
  /// the runner to the same contract a real sink would.
  final Set<String> failingTables = <String>{};

  int flushCalls = 0;
  bool closed = false;

  var _down = false;
  var _written = 0;
  var _dropped = 0;
  String? _lastError;
  final _connected = StreamController<bool>.broadcast();

  /// Buffering without accepting — the database is unreachable but the
  /// sink, like the real one, keeps taking samples.
  void goDown() {
    _down = true;
    _connected.add(false);
  }

  /// Accepts everything buffered while down, in arrival order.
  void comeUp() {
    _down = false;
    accepted.addAll(buffered);
    _written += buffered.length;
    buffered.clear();
    _connected.add(true);
  }

  @override
  Future<void> ensureTable(String table, RetentionPolicy? retention) async {
    ensureCalls++;
    ensuredTables[table] = retention;
  }

  @override
  Future<void> insert(String table, DateTime time, Object? value) async {
    if (failingTables.contains(table)) {
      _dropped++;
      // Redacted by construction: names the table, never a host or a user.
      _lastError = 'FakeSink: table "$table" is set to fail';
      return;
    }
    final row = FakeSinkRow(table, time, value);
    if (_down) {
      buffered.add(row);
    } else {
      accepted.add(row);
      _written++;
    }
  }

  @override
  Future<void> flush() async {
    flushCalls++;
  }

  @override
  Future<void> close() async {
    closed = true;
    await _connected.close();
  }

  @override
  SinkStats get stats => SinkStats(
        rowsWritten: _written,
        rowsDropped: _dropped,
        rowsQueued: buffered.length,
        lastError: _lastError,
      );

  @override
  Stream<bool> get connected => _connected.stream;
}
