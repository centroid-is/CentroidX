import 'dart:convert';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/src/history_view.dart';
import 'package:tfc_relay_protocol/src/timeseries.dart';

/// The data-service surfaces exchange plain records, never ORM-generated rows
/// and never untyped map bags. Every shape must survive
/// encode → jsonEncode → jsonDecode → decode with unknown fields ignored.
void main() {
  Map<String, Object?> viaJson(Map<String, Object?> json,
          {Map<String, Object?> extra = const {'futureField': 123}}) =>
      jsonDecode(jsonEncode({...json, ...extra})) as Map<String, Object?>;

  group('TimeseriesData', () {
    test('round-trips with time as UTC epoch milliseconds', () {
      final t = DateTime.utc(2026, 8, 13, 9, 30, 15, 250);
      final sample = TimeseriesData<double>(3.5, t);

      expect(sample.toJson()['t'], t.millisecondsSinceEpoch,
          reason: 'timestamps are UTC epoch milliseconds as int throughout '
              'the protocol package (WireValue.t, SubTick.evaluatedAt)');
      expect(sample.toJson()['t'], isA<int>());

      final decoded = TimeseriesData<double>.fromJson(viaJson(sample.toJson()));
      expect(decoded.value, 3.5);
      expect(decoded.time, t);
      expect(decoded.time.isUtc, isTrue);
      expect(decoded, sample);
    });

    test('a local-time sample decodes back as the same instant in UTC', () {
      final local = DateTime(2026, 8, 13, 9, 30, 15, 250);
      final sample = TimeseriesData<int>(42, local);

      final decoded = TimeseriesData<int>.fromJson(viaJson(sample.toJson()));
      expect(decoded.time.isUtc, isTrue);
      expect(decoded.time.millisecondsSinceEpoch, local.millisecondsSinceEpoch,
          reason: 'the wire carries an absolute instant; the panel decides '
              'how to display it');
      expect(decoded, sample);
    });

    test('a non-finite value is nulled at construction, never on encode', () {
      final t = DateTime.utc(2026, 8, 13);
      final poison = TimeseriesData<double?>(double.nan, t);

      expect(poison.value, isNull,
          reason: 'one open-circuit 4-20 mA input must not fail the batch '
              'for every connected client');
      expect(jsonEncode(poison.toJson()), isNotEmpty);
      expect(TimeseriesData<double?>.fromJson(viaJson(poison.toJson())).value,
          isNull);
    });

    test('a non-finite value under a non-nullable T is nulled on encode', () {
      final t = DateTime.utc(2026, 8, 13);
      final poison = TimeseriesData<double>(double.infinity, t);

      expect(poison.toJson()['v'], isNull,
          reason: 'construction can never throw either, so the poison is '
              'held in the field and nulled at the boundary');
      expect(jsonEncode(poison.toJson()), isNotEmpty);
    });

    test('a retained non-finite sample is equal to itself', () {
      // WR-12. The constructor keeps the poison when T does not admit null,
      // and NaN != NaN — so the sample was unequal to itself while its
      // hashCode stayed stable, breaking the Set/Map contract. Any
      // de-duplication downstream then silently keeps every copy.
      final t = DateTime.utc(2026, 8, 13);
      final poison = TimeseriesData<double>(double.nan, t);

      expect(poison, poison);
      expect(poison, TimeseriesData<double>(double.nan, t));
      expect({poison, TimeseriesData<double>(double.nan, t)}, hasLength(1),
          reason: 'two samples that encode identically are one sample');
      expect(poison.hashCode, TimeseriesData<double>(double.nan, t).hashCode);
    });

    test('equality still separates samples that encode differently', () {
      final t = DateTime.utc(2026, 8, 13);
      expect(TimeseriesData<double>(1.5, t),
          isNot(TimeseriesData<double>(2.5, t)));
      expect(TimeseriesData<double>(1.5, t),
          isNot(TimeseriesData<double>(1.5, t.add(const Duration(days: 1)))));
      expect(TimeseriesData<double>(double.nan, t),
          isNot(TimeseriesData<double>(0.0, t)),
          reason: 'a retained NaN encodes as null, and null is not zero');
    });

    test('1e999 decoded from the wire cannot survive into a re-encode', () {
      final wire = jsonDecode('{"v": 1e999, "t": 0}') as Map<String, Object?>;

      final decoded = TimeseriesData<double?>.fromJson(wire);
      expect(decoded.value, isNull,
          reason: '1e999 silently decodes to Infinity and would detonate on '
              'the next encode');
      expect(jsonEncode(decoded.toJson()), isNotEmpty);
    });

    test('an int on the wire coerces to double when T is double', () {
      final decoded =
          TimeseriesData<double>.fromJson(const {'v': 7, 't': 1000});
      expect(decoded.value, 7.0);
      expect(decoded.time, DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true));
    });

    test('a caller-supplied decoder handles non-primitive values', () {
      final decoded = TimeseriesData<List<int>>.fromJson(
        const {
          'v': [1, 2, 3],
          't': 0
        },
        decode: (raw) => (raw as List).cast<int>(),
      );
      expect(decoded.value, [1, 2, 3]);
    });
  });

  group('HistoryViewRecord', () {
    test('round-trips and tolerates unknown fields', () {
      final record = HistoryViewRecord(
        id: 7,
        name: 'Frystir – hitastig',
        createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5, 678),
        updatedAt: DateTime.utc(2026, 2, 3, 4, 5, 6, 789),
      );

      final decoded = HistoryViewRecord.fromJson(viaJson(record.toJson()));
      expect(decoded, record);
      expect(decoded.name, 'Frystir – hitastig');
      expect(decoded.updatedAt, DateTime.utc(2026, 2, 3, 4, 5, 6, 789));
    });

    test('a never-updated view omits updatedAt from JSON', () {
      final record = HistoryViewRecord(
        id: 1,
        name: 'v',
        createdAt: DateTime.utc(2026, 1, 1),
      );

      expect(record.toJson().containsKey('updatedAt'), isFalse);
      final decoded = HistoryViewRecord.fromJson(viaJson(record.toJson()));
      expect(decoded.updatedAt, isNull);
      expect(decoded, record);
    });
  });

  group('HistoryViewKeyRecord', () {
    test('alias defaults to the key when the JSON omits it', () {
      final decoded =
          HistoryViewKeyRecord.fromJson(const {'key': 'ST101.CN01.Speed'});

      expect(decoded.alias, 'ST101.CN01.Speed',
          reason: "matches getHistoryViewKeys's row.alias ?? row.key — a key "
              'with no alias still needs a legend label');
      expect(decoded.useSecondYAxis, isFalse);
      expect(decoded.graphIndex, 0);
    });

    test('alias defaults to the key at construction too', () {
      const record = HistoryViewKeyRecord(key: 'k');
      expect(record.alias, 'k');
    });

    test('round-trips a fully specified key', () {
      const record = HistoryViewKeyRecord(
        key: 'ST201.CN14.MTR01.Speed',
        alias: 'Hraði',
        useSecondYAxis: true,
        graphIndex: 2,
      );

      final decoded = HistoryViewKeyRecord.fromJson(viaJson(record.toJson()));
      expect(decoded, record);
      expect(decoded.useSecondYAxis, isTrue);
      expect(decoded.graphIndex, 2);
    });
  });

  group('HistoryViewGraphRecord', () {
    test('the three string fields default to empty when absent', () {
      final decoded =
          HistoryViewGraphRecord.fromJson(const {'graphIndex': 1});

      expect(decoded.name, '');
      expect(decoded.yAxisUnit, '');
      expect(decoded.yAxis2Unit, '',
          reason: "matches getHistoryViewGraphs's ?? '' — an unnamed axis "
              'renders blank, it does not crash the chart');
      expect(decoded.graphIndex, 1);
    });

    test('round-trips and tolerates unknown fields', () {
      const record = HistoryViewGraphRecord(
        graphIndex: 3,
        name: 'Þyngd',
        yAxisUnit: 'kg',
        yAxis2Unit: 'm/s',
      );

      expect(HistoryViewGraphRecord.fromJson(viaJson(record.toJson())), record);
    });

    test('a graph map keyed by int survives the JSON boundary', () {
      const graphs = <int, HistoryViewGraphRecord>{
        0: HistoryViewGraphRecord(graphIndex: 0, name: 'Hiti', yAxisUnit: '°C'),
        2: HistoryViewGraphRecord(graphIndex: 2, name: 'Þyngd', yAxisUnit: 'kg'),
      };

      final encoded = jsonEncode(historyViewGraphsToJson(graphs));
      expect(jsonDecode(encoded), containsPair('2', isA<Map>()),
          reason: 'JSON objects key by String; graph indexes are ints — '
              'convert at the boundary, never in the caller');

      final decoded = historyViewGraphsFromJson(jsonDecode(encoded));
      expect(decoded.keys, [0, 2]);
      expect(decoded[2]!.name, 'Þyngd');
      expect(decoded, graphs);
    });

    test('an absent graph map decodes to empty, not to a throw', () {
      expect(historyViewGraphsFromJson(null), isEmpty);
    });
  });

  group('HistoryViewPeriodRecord', () {
    test('round-trips and tolerates unknown fields', () {
      final record = HistoryViewPeriodRecord(
        id: 11,
        viewId: 7,
        name: 'Vakt 1',
        startAt: DateTime.utc(2026, 8, 13, 6),
        endAt: DateTime.utc(2026, 8, 13, 14),
        createdAt: DateTime.utc(2026, 8, 12, 22, 15),
      );

      final decoded =
          HistoryViewPeriodRecord.fromJson(viaJson(record.toJson()));

      expect(decoded, record);
      expect(decoded.startAt.isUtc, isTrue);
      expect(decoded.endAt, DateTime.utc(2026, 8, 13, 14));
      expect(decoded.viewId, 7);
    });

    test('numbers arriving as doubles still decode to int ids', () {
      final decoded = HistoryViewPeriodRecord.fromJson(const {
        'id': 11.0,
        'viewId': 7.0,
        'name': 'p',
        'startAt': 0,
        'endAt': 1000,
        'createdAt': 0,
      });

      expect(decoded.id, 11);
      expect(decoded.viewId, 7);
    });
  });
}
