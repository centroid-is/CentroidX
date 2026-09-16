import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart' show DatabaseConfig;
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/lid_inspection.dart';

class _Db extends AppDatabase {
  _Db() : super.forTest(DatabaseConfig(), NativeDatabase.memory());
}

/// The service's DDL, minus the Postgres-only pieces SQLite rejects. The
/// column list and names are what the store's SQL depends on, and those are
/// identical.
String _sqliteDdl() => kLidInspectionDdl
    .replaceAll('TIMESTAMPTZ', 'TEXT')
    .replaceAll('DOUBLE PRECISION', 'REAL')
    .replaceAll('BYTEA', 'BLOB')
    .replaceAll('BOOLEAN', 'INTEGER');

Future<void> _insert(
  _Db db, {
  required String id,
  String camera = 'LID01',
  required String time,
  double score = 0.3,
  double threshold = 0.62,
  bool anomaly = false,
  bool armed = true,
  String? lidType = 'lid_40x30_a',
  String? modelVersion = 'patchcore_r18_2026-09-10',
  int? inferenceMs = 180,
  Uint8List? image,
  Uint8List? heatmap,
}) {
  return db.customStatement(
    'INSERT INTO lid_inspection (id, camera, time, score, threshold, anomaly, '
    'armed, lid_type, model_version, inference_ms, image, heatmap) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [
      id,
      camera,
      time,
      score,
      threshold,
      anomaly ? 1 : 0,
      armed ? 1 : 0,
      lidType,
      modelVersion,
      inferenceMs,
      image,
      heatmap,
    ],
  );
}

void main() {
  group('parseInspectionTime', () {
    test('reads the text Postgres prints for a timestamptz', () {
      // Space separator, milliseconds, two-digit zone — the psql/driver text
      // form, which is what CAST(time AS TEXT) yields.
      expect(parseInspectionTime('2026-09-15 14:30:12.123+00'),
          DateTime.utc(2026, 9, 15, 14, 30, 12, 123));
    });

    test('honours a non-UTC session zone', () {
      expect(parseInspectionTime('2026-09-15 16:30:12+02'),
          DateTime.utc(2026, 9, 15, 14, 30, 12));
    });

    test('reads ISO 8601 as a service might write it directly', () {
      expect(parseInspectionTime('2026-09-15T14:30:12.123Z'),
          DateTime.utc(2026, 9, 15, 14, 30, 12, 123));
    });

    test('is null, not a throw, for garbage or nothing', () {
      expect(parseInspectionTime(null), isNull);
      expect(parseInspectionTime(''), isNull);
      expect(parseInspectionTime('yesterday'), isNull);
    });
  });

  group('DatabaseLidInspectionStore', () {
    late _Db db;
    late DatabaseLidInspectionStore store;

    setUp(() async {
      db = _Db();
      for (final statement in _sqliteDdl().split(';')) {
        if (statement.trim().isEmpty) continue;
        await db.customStatement(statement);
      }
      store = DatabaseLidInspectionStore(db);
    });
    tearDown(() => db.close());

    test('latest is null for a camera with no rows', () async {
      expect(await store.latest('LID01'), isNull);
      expect(await store.recent('LID01'), isEmpty);
    });

    test('latest is the newest row for that camera only', () async {
      await _insert(db, id: 'a', time: '2026-09-15 14:30:00+00');
      await _insert(db,
          id: 'b', time: '2026-09-15 14:30:05+00', score: 0.71, anomaly: true);
      await _insert(db,
          id: 'other', camera: 'LID02', time: '2026-09-15 14:31:00+00');

      final latest = await store.latest('LID01');
      expect(latest, isNotNull);
      expect(latest!.id, 'b');
      expect(latest.camera, 'LID01');
      expect(latest.time, DateTime.utc(2026, 9, 15, 14, 30, 5));
      expect(latest.score, 0.71);
      expect(latest.threshold, 0.62);
      expect(latest.anomaly, isTrue);
      expect(latest.armed, isTrue);
      expect(latest.lidType, 'lid_40x30_a');
      expect(latest.modelVersion, 'patchcore_r18_2026-09-10');
      expect(latest.inferenceMs, 180);
      expect(latest.hasImage, isFalse,
          reason: 'no bytes were stored for this lid');
    });

    test('recent lists anomalies newest first, capped by limit', () async {
      for (var i = 0; i < 6; i++) {
        await _insert(db,
            id: 'r$i',
            time: '2026-09-15 14:3${i}:00+00',
            score: i.isEven ? 0.9 : 0.2,
            anomaly: i.isEven);
      }
      final recent = await store.recent('LID01', limit: 2);
      expect(recent.map((r) => r.id), ['r4', 'r2']);
      expect(recent.every((r) => r.anomaly), isTrue);

      final all = await store.recent('LID01', anomaliesOnly: false, limit: 10);
      expect(all.map((r) => r.id), ['r5', 'r4', 'r3', 'r2', 'r1', 'r0']);
    });

    test('image and heatmap bytes come back as stored, null when absent',
        () async {
      final jpg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
      final heat = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 9, 9]);
      await _insert(db,
          id: 'with',
          time: '2026-09-15 14:30:00+00',
          anomaly: true,
          image: jpg,
          heatmap: heat);
      await _insert(db, id: 'without', time: '2026-09-15 14:31:00+00');

      expect(await store.image('with'), jpg);
      expect(await store.image('with', heatmap: true), heat);
      expect(await store.image('without'), isNull);
      expect(await store.image('missing'), isNull);
      expect((await store.latest('LID01'))!.hasImage, isFalse);
      expect((await store.recent('LID01')).single.hasImage, isTrue);
    });

    test('a row with an unreadable time is skipped, not fatal', () async {
      await _insert(db, id: 'bad', time: 'not a time');
      await _insert(db, id: 'good', time: '2026-09-15 14:30:00+00');
      expect((await store.recent('LID01', anomaliesOnly: false))
          .map((r) => r.id), ['good']);
    });

    test('the query fails loudly when the service has not created the table',
        () async {
      final bare = _Db();
      addTearDown(bare.close);
      expect(DatabaseLidInspectionStore(bare).latest('LID01'),
          throwsA(isA<Exception>()));
    });

    test('recordFromRow accepts Postgres-shaped values', () {
      // Postgres hands drift real bools and doubles; the SQLite harness above
      // hands ints. Both must read the same.
      final record = DatabaseLidInspectionStore.recordFromRow({
        'id': 'pg',
        'camera': 'LID01',
        'time_text': '2026-09-15 14:30:12.5+00',
        'score': 0.87,
        'threshold': 0.62,
        'anomaly': true,
        'armed': false,
        'lid_type': null,
        'model_version': 'v1',
        'inference_ms': 210,
        'has_image': true,
      });
      expect(record, isNotNull);
      expect(record!.anomaly, isTrue);
      expect(record.armed, isFalse);
      expect(record.hasImage, isTrue);
      expect(record.lidType, isNull);
      expect(record.time, DateTime.utc(2026, 9, 15, 14, 30, 12, 500));
    });
  });
}
