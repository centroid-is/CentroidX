@TestOn('vm')

/// The tracker on a transport that does not push.
///
/// `TimeseriesKeyTracker` is the shared per-key cache behind every counting
/// and rate readout on a mimic. Until this change its first line was
/// `final db = await _database(); if (db == null || !_alive) return;` — and a
/// gateway panel's `databaseProvider` is null by design, so on every such panel
/// the tracker returned there and did nothing for the rest of its life. The
/// readouts sat at zero. Nothing said why.
///
/// These arms are about the state that fix introduces and the plant behaviour
/// that hangs off it: a source that answers `liveInserts` with **null** is a
/// transport with no push channel, and the tracker must poll it on purpose
/// rather than treat the absence as a channel that failed to open.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/timeseries_source.dart';
import 'package:tfc/providers/timeseries.dart';
import 'package:tfc_dart/core/database.dart' as db;
import 'package:tfc_dart/core/state_man.dart';

/// A StateMan that resolves a key to itself. `resolveKey` is the only member
/// the tracker touches.
class _FakeStateMan extends Fake implements StateMan {
  @override
  String resolveKey(String key) => key;
}

/// A source whose three behaviours an arm sets directly: what it answers, what
/// it pushes, and whether it fails.
final class _FakeSource implements TimeseriesSource {
  _FakeSource({this.pushes = false});

  /// Whether [liveInserts] hands out a stream (a database) or null (the pipe).
  final bool pushes;

  /// The controller behind the push channel, when there is one.
  StreamController<TimeseriesInsert>? pushed;

  /// Rows every query answers.
  List<db.TimeseriesData<dynamic>> rows = const [];

  /// Thrown by every query when set.
  Object? failure;

  int queries = 0;
  int liveInsertAttempts = 0;

  @override
  Future<List<db.TimeseriesData<dynamic>>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    queries++;
    final boom = failure;
    if (boom != null) throw boom;
    return rows;
  }

  @override
  Future<Map<String, List<db.TimeseriesData<dynamic>>>>
      queryTimeseriesDataMultiple(List<String> tableNames, DateTime to,
              {String? orderBy = 'time ASC', DateTime? from}) async =>
          {for (final t in tableNames) t: rows};

  @override
  Future<List<db.TimeseriesData<dynamic>>> queryTimeseriesDataDownsampled(
          String tableName, DateTime from, DateTime to,
          {int maxPoints = 1000}) async =>
      rows;

  @override
  Future<Stream<TimeseriesInsert>?> liveInserts(String tableName) async {
    liveInsertAttempts++;
    if (!pushes) return null;
    final controller = StreamController<TimeseriesInsert>();
    pushed = controller;
    addTearDown(controller.close);
    return controller.stream;
  }
}

void main() {
  final DateTime now = DateTime.utc(2026, 9, 9, 12);

  /// A tracker over [source], torn down with the test.
  TimeseriesKeyTracker trackerOver(_FakeSource source) {
    final tracker = TimeseriesKeyTracker(
      tsKey: 'CN04.MOT01',
      source: () async => source,
      stateMan: () async => _FakeStateMan(),
    );
    addTearDown(tracker.dispose);
    // A window, exactly as a readout attaching asks for one. Without it the
    // initial fetch spans zero minutes and every arm below reads an empty
    // cache for a reason that has nothing to do with the transport.
    tracker.attach(windowMinutes: 60);
    return tracker;
  }

  group('a source that does not push — the gateway panel', () {
    test('start() fetches history and fills the cache', () async {
      final source = _FakeSource()
        ..rows = [
          db.TimeseriesData(1, now.subtract(const Duration(minutes: 2))),
          db.TimeseriesData(2, now.subtract(const Duration(minutes: 1))),
        ];
      final tracker = trackerOver(source);

      await tracker.start();

      expect(source.queries, greaterThan(0),
          reason: 'this is the whole gap. Before the source seam the tracker '
              'returned on `db == null` and never issued a query on a gateway '
              'panel — the readouts sat at zero on a plant that had been '
              'recording all week');
      expect(tracker.cache.countSince('CN04.MOT01',
              now.subtract(const Duration(minutes: 10))),
          2);
    });

    test('it reports that it is polling, rather than looking like a failed '
        'subscription', () async {
      final source = _FakeSource();
      final tracker = trackerOver(source);

      await tracker.start();

      expect(tracker.transportPushes, isFalse,
          reason: 'null from liveInserts means "this transport has no push '
              'channel", which is a different fact from a channel that could '
              'not be opened. A tracker that conflated them would back off and '
              'warn on every sweep about a subscription that was never coming');
      expect(source.liveInsertAttempts, 1,
          reason: 'and it asks once. Retrying a channel the transport has '
              'said it does not have is the same cry-wolf loop by a longer '
              'route');
    });

    test('a failed fetch is recorded on the tracker, not swallowed', () async {
      final source = _FakeSource()
        ..failure = StateError('the gateway could not read timescale');
      final tracker = trackerOver(source);

      await tracker.start();

      expect(tracker.fetchError, isNotNull,
          reason: 'an empty cache and a failed read look identical on a chart. '
              'A readout drawing zero because the gateway is unreachable must '
              'have somewhere to say so — the same rule RelayAlarmSource\'s '
              'historyError carries');
      expect(tracker.fetchError, contains('timescale'));
    });

    test('a fetch that works after one that failed clears the fault', () async {
      final source = _FakeSource()..failure = StateError('down');
      final tracker = trackerOver(source);
      await tracker.start();
      expect(tracker.fetchError, isNotNull);

      source.failure = null;
      source.rows = [db.TimeseriesData(7, now)];
      await tracker.refreshNow();

      expect(tracker.fetchError, isNull,
          reason: 'a stale fault line is a fault line nobody reads');
    });
  });

  group('a source that pushes — the direct-mode station', () {
    test('an insert on the channel lands in the cache and notifies', () async {
      final source = _FakeSource(pushes: true);
      final tracker = trackerOver(source);
      await tracker.start();

      expect(tracker.transportPushes, isTrue);

      var notified = 0;
      tracker.addListener(() => notified++);
      source.pushed!.add((time: now, value: 5));
      await Future<void>.delayed(Duration.zero);

      expect(
          tracker.cache.countSince(
              'CN04.MOT01', now.subtract(const Duration(minutes: 1))),
          1);
      expect(notified, 1);
    });
  });
}
