@TestOn('vm')

/// Gap A: the timeseries surface follows the transport.
///
/// `TimeseriesKeyTracker.start()` used to open with
/// `final db = await _database(); if (db == null || !_alive) return;`. On a
/// gateway panel `databaseProvider` is null **by design**, so that line was the
/// whole of the tracker's life: it returned, never subscribed, never fetched,
/// and every chart and trend readout on the panel drew nothing. No error, no
/// badge, no line on stderr — a plant that has been recording all week rendered
/// as a plant with no history.
///
/// This file pins the seam that fixes it. Three properties, and each of them is
/// a thing an operator would otherwise have to discover from a blank chart:
///
///  * **Both transports answer the same three questions**, so a chart cannot
///    tell which one answered.
///  * **A relayed failure throws.** It is never an empty sample list:
///    `[]` is what a quiet tag looks like, and the two must not be spelled the
///    same way (`relay_alarm_source.dart`'s rule, applied to the second
///    surface).
///  * **"This transport does not push" is a third state**, distinct from "the
///    push channel failed to open". The relay has no LISTEN/NOTIFY and never
///    will; a tracker that read that absence as a failure would back off,
///    log a warning per sweep, and still be right about the data — the state
///    has to be nameable so the poll can be the plan rather than the fallback.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/timeseries_source.dart';
import 'package:tfc_dart/core/database.dart' as db;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as rp;

// -----------------------------------------------------------------------------
// A recording TimeseriesApi — the far end, without a socket
// -----------------------------------------------------------------------------

/// What the relay was asked, and what it answered.
///
/// Recording the *request* is the only way an arm can state "the window the
/// chart asked for is the window that crossed the wire" as a property. A fake
/// that only answered would let an adapter silently widen, narrow or reorder a
/// query and every arm would still pass.
final class _RecordingTimeseriesApi implements rp.TimeseriesApi {
  final List<String> asked = <String>[];

  /// Samples answered per table. A table absent from here answers none.
  final Map<String, List<rp.TimeseriesData>> rows =
      <String, List<rp.TimeseriesData>>{};

  /// Thrown by every member when set — "the gateway could not answer".
  Object? failure;

  DateTime? lastTo;
  DateTime? lastFrom;
  String? lastOrderBy;
  int? lastMaxPoints;

  @override
  Future<List<rp.TimeseriesData>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    asked.add(tableName);
    lastTo = to;
    lastFrom = from;
    lastOrderBy = orderBy;
    final boom = failure;
    if (boom != null) throw boom;
    return rows[tableName] ?? const [];
  }

  /// **Answers a SHORT map on purpose.** A table with no rows is simply absent
  /// from the answer, which is what the far end really does: the gateway's
  /// policy filter drops a series this station may not see, and a backend
  /// older than `data_handlers.dart:334-348` answered whatever its reader
  /// found. A fake that echoed the request back would make the "one entry per
  /// requested table" property untestable — the adapter could key off the
  /// answer and every arm would still pass.
  @override
  Future<Map<String, List<rp.TimeseriesData>>> queryTimeseriesDataMultiple(
      List<String> tableNames, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    asked.addAll(tableNames);
    lastTo = to;
    lastFrom = from;
    lastOrderBy = orderBy;
    final boom = failure;
    if (boom != null) throw boom;
    return {
      for (final table in tableNames)
        if (rows[table] != null) table: rows[table]!,
    };
  }

  @override
  Future<List<rp.TimeseriesData>> queryTimeseriesDataDownsampled(
      String tableName, DateTime from, DateTime to,
      {int maxPoints = 1000}) async {
    asked.add(tableName);
    lastFrom = from;
    lastTo = to;
    lastMaxPoints = maxPoints;
    final boom = failure;
    if (boom != null) throw boom;
    return rows[tableName] ?? const [];
  }
}

rp.TimeseriesData _sample(num value, DateTime at) =>
    rp.TimeseriesData<num>(value, at);

void main() {
  final DateTime to = DateTime.utc(2026, 9, 9, 12);
  final DateTime from = to.subtract(const Duration(hours: 1));

  group('RelayedTimeseriesSource — the three reads', () {
    test('queryTimeseriesData answers the gateway\'s samples as the type the '
        'charts already draw', () async {
      final api = _RecordingTimeseriesApi()
        ..rows['CN04.MOT01'] = [
          _sample(41, from),
          _sample(42, to),
        ];

      final samples = await RelayedTimeseriesSource(api)
          .queryTimeseriesData('CN04.MOT01', from);

      expect(samples, hasLength(2));
      expect(samples, everyElement(isA<db.TimeseriesData<dynamic>>()),
          reason: 'the call sites draw `tfc_dart`\'s TimeseriesData. An '
              'adapter that leaked the protocol type would compile only where '
              'the call site was also edited, which is how half a page ends '
              'up on one transport and half on the other');
      expect(samples.map((s) => s.value), [41, 42]);
      expect(samples.map((s) => s.time), [from, to]);
    });

    test('the window and the ordering the caller asked for are what crosses '
        'the wire', () async {
      final api = _RecordingTimeseriesApi();

      await RelayedTimeseriesSource(api).queryTimeseriesData('CN04.MOT01', to,
          from: from, orderBy: 'time DESC');

      expect(api.asked, ['CN04.MOT01']);
      expect(api.lastTo, to);
      expect(api.lastFrom, from);
      expect(api.lastOrderBy, 'time DESC',
          reason: 'a chart that asked for newest-first and got oldest-first '
              'draws the line backwards without saying so');
    });

    test('queryTimeseriesDataMultiple keeps one entry per requested table',
        () async {
      final api = _RecordingTimeseriesApi()
        ..rows['a'] = [_sample(1, to)];

      final answer = await RelayedTimeseriesSource(api)
          .queryTimeseriesDataMultiple(['a', 'b'], to, from: from);

      expect(answer.keys, containsAll(['a', 'b']),
          reason: 'an absent entry and an empty entry are different answers: a '
              'chart that iterates the names it asked for drops a missing one '
              'from its legend, which an operator reads as "this tag is flat" '
              'rather than as "nothing was recorded"');
      expect(answer['a']!.single.value, 1);
      expect(answer['b'], isEmpty);
    });

    test('queryTimeseriesDataDownsampled carries maxPoints', () async {
      final api = _RecordingTimeseriesApi();

      await RelayedTimeseriesSource(api)
          .queryTimeseriesDataDownsampled('a', from, to, maxPoints: 400);

      expect(api.lastMaxPoints, 400,
          reason: 'the bucketing happens where the data is. A dropped '
              'maxPoints falls back to the unbounded raw query on the '
              'gateway, which is the one thing the downsampled method exists '
              'to avoid');
    });
  });

  group('RelayedTimeseriesSource — a failure is never an empty series', () {
    test('a gateway failure throws out of queryTimeseriesData', () async {
      final api = _RecordingTimeseriesApi()
        ..failure = StateError('the gateway could not read timescale');

      await expectLater(
        RelayedTimeseriesSource(api).queryTimeseriesData('a', to),
        throwsA(isA<StateError>()),
        reason: 'an empty list here is what a quiet tag looks like. Returning '
            'one for a failed read reports a fact about the wire as a fact '
            'about the factory — the failure class this milestone exists to '
            'remove',
      );
    });

    test('a gateway failure throws out of queryTimeseriesDataMultiple, rather '
        'than answering the short map', () async {
      final api = _RecordingTimeseriesApi()
        ..failure = StateError('the gateway could not read timescale');

      await expectLater(
        RelayedTimeseriesSource(api)
            .queryTimeseriesDataMultiple(['a', 'b'], to),
        throwsA(isA<StateError>()),
      );
    });

    test('a gateway failure throws out of queryTimeseriesDataDownsampled',
        () async {
      final api = _RecordingTimeseriesApi()
        ..failure = StateError('the gateway could not read timescale');

      await expectLater(
        RelayedTimeseriesSource(api)
            .queryTimeseriesDataDownsampled('a', from, to),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('RelayedTimeseriesSource — the push channel that does not exist', () {
    test('liveInserts answers null, which is not the same as a failed open',
        () async {
      final source = RelayedTimeseriesSource(_RecordingTimeseriesApi());

      expect(await source.liveInserts('CN04.MOT01'), isNull,
          reason: 'the pipe carries no LISTEN/NOTIFY and no plan adds one. '
              'Null is the transport saying "there is nothing to subscribe '
              'to", which is what lets a tracker poll on purpose. A throw '
              'here would be indistinguishable from a channel that could not '
              'be opened, and the tracker would back off and warn on every '
              'sweep about a channel that was never coming');
    });

    test('the null answer is not a one-shot: asking twice answers twice',
        () async {
      final source = RelayedTimeseriesSource(_RecordingTimeseriesApi());

      expect(await source.liveInserts('a'), isNull);
      expect(await source.liveInserts('a'), isNull);
    });
  });
}
