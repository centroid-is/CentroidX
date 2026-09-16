/// Camera lid-inspection results, as the HMI reads them.
///
/// The inspection itself runs in a separate service (Python: camera grab,
/// anomaly model, threshold). That service publishes two things and this file
/// reads the second:
///
///  1. **Live state over OPC UA** — score, threshold, armed, anomaly, training
///     state — which the HMI subscribes to like any PLC tag, so the alarm
///     system, the collector and the access rules all apply unchanged. See
///     `lib/page_creator/assets/lid_inspection.dart` for the node contract.
///  2. **One row per inspected lid in Postgres** — the record, with the
///     inspected frame and its heat-map as JPEG bytes for the lids that
///     tripped the threshold (and a sample of near-misses for tuning).
///
/// The service owns the table: it runs [kLidInspectionDdl] at start-up and
/// its own retention job. The HMI only ever reads it, through a
/// [LidInspectionStore]. There is no drift table class on purpose — a table
/// another process creates and migrates is not something this package should
/// also claim to migrate.
///
/// Why Postgres for images rather than an HTTP route: the backend has no
/// HTTP server, no asset fetches over the network today, and the closest
/// precedent for "an external process hands the HMI a file" is the technical
/// document library, which stores PDF bytes in a `BYTEA` column. Same shape
/// here, same read path.
library;

import 'dart:typed_data';

import 'package:drift/drift.dart';

/// The table the inspection service creates. Kept here so the asset's help
/// text and the service's start-up statement come from one place.
///
/// `image`/`heatmap` are a *downscaled preview* (the service writes ~1024 px
/// on the long side, JPEG ~85 %); the full-resolution frame stays on the
/// service's disk under the same `id`, for engineers, not for the panel.
const String kLidInspectionDdl = '''
CREATE TABLE IF NOT EXISTS lid_inspection (
  id            TEXT PRIMARY KEY,
  camera        TEXT NOT NULL,
  time          TIMESTAMPTZ NOT NULL,
  score         DOUBLE PRECISION NOT NULL,
  threshold     DOUBLE PRECISION NOT NULL,
  anomaly       BOOLEAN NOT NULL,
  armed         BOOLEAN NOT NULL,
  lid_type      TEXT,
  model_version TEXT,
  inference_ms  INTEGER,
  image         BYTEA,
  heatmap       BYTEA
);
CREATE INDEX IF NOT EXISTS lid_inspection_camera_time
  ON lid_inspection (camera, time DESC);
''';

/// One inspected lid.
class LidInspectionRecord {
  final String id;
  final String camera;
  final DateTime time;
  final double score;
  final double threshold;

  /// Whether [score] reached [threshold] when the lid was inspected. Stored,
  /// not recomputed: the threshold can be re-tuned later and the record must
  /// still say what the service decided at the time.
  final bool anomaly;

  /// False while the service was in shadow mode — the verdict was logged but
  /// no alarm was meant to follow.
  final bool armed;
  final String? lidType;
  final String? modelVersion;
  final int? inferenceMs;

  /// Whether a preview frame was stored for this lid. The service keeps
  /// images for anomalies and a sample of near-misses only, so most OK rows
  /// carry none.
  final bool hasImage;

  const LidInspectionRecord({
    required this.id,
    required this.camera,
    required this.time,
    required this.score,
    required this.threshold,
    required this.anomaly,
    required this.armed,
    this.lidType,
    this.modelVersion,
    this.inferenceMs,
    this.hasImage = false,
  });

  @override
  String toString() =>
      'LidInspectionRecord($id, $camera, $time, score $score/$threshold, '
      'anomaly: $anomaly, armed: $armed, image: $hasImage)';
}

/// Read access to the inspection records of one or more cameras.
abstract interface class LidInspectionStore {
  /// The most recent record for [camera], anomaly or not; null when the
  /// camera has never inspected anything.
  Future<LidInspectionRecord?> latest(String camera);

  /// The most recent records for [camera], newest first. With
  /// [anomaliesOnly] (the default) only lids that tripped the threshold.
  Future<List<LidInspectionRecord>> recent(String camera,
      {int limit = 10, bool anomaliesOnly = true});

  /// The stored preview JPEG for record [id] — the frame, or with [heatmap]
  /// the heat-map overlay. Null when none was stored.
  Future<Uint8List?> image(String id, {bool heatmap = false});
}

/// Parses the `time` column as the database prints it.
///
/// The query casts the timestamp to text so the same SQL reads on Postgres
/// and on the SQLite test harness. Postgres prints a `timestamptz` as
/// `2026-09-15 14:30:12.123+00` — space separator, fractional seconds, a
/// two-digit zone — all of which `DateTime.parse` accepts; a service that
/// wrote ISO 8601 with `T` and `Z` parses too. Null for anything else rather
/// than a throw: one unreadable row must not take the pane down.
DateTime? parseInspectionTime(String? text) {
  if (text == null || text.isEmpty) return null;
  return DateTime.tryParse(text.trim())?.toUtc();
}

/// [LidInspectionStore] over the `lid_inspection` table through drift's raw
/// query API — no generated table class, see the library comment.
class DatabaseLidInspectionStore implements LidInspectionStore {
  DatabaseLidInspectionStore(this._db);

  final GeneratedDatabase _db;

  static const _columns = 'id, camera, CAST(time AS TEXT) AS time_text, '
      'score, threshold, anomaly, armed, lid_type, model_version, '
      'inference_ms, (image IS NOT NULL) AS has_image';

  @override
  Future<LidInspectionRecord?> latest(String camera) async {
    final rows = await _db.customSelect(
      'SELECT $_columns FROM lid_inspection WHERE camera = ? '
      'ORDER BY time DESC LIMIT 1',
      variables: [Variable.withString(camera)],
    ).get();
    if (rows.isEmpty) return null;
    return recordFromRow(rows.first.data);
  }

  @override
  Future<List<LidInspectionRecord>> recent(String camera,
      {int limit = 10, bool anomaliesOnly = true}) async {
    final rows = await _db.customSelect(
      'SELECT $_columns FROM lid_inspection WHERE camera = ? '
      '${anomaliesOnly ? 'AND anomaly ' : ''}'
      'ORDER BY time DESC LIMIT ?',
      variables: [Variable.withString(camera), Variable.withInt(limit)],
    ).get();
    return [
      for (final row in rows)
        if (recordFromRow(row.data) case final r?) r,
    ];
  }

  @override
  Future<Uint8List?> image(String id, {bool heatmap = false}) async {
    final column = heatmap ? 'heatmap' : 'image';
    final rows = await _db.customSelect(
      'SELECT $column AS bytes FROM lid_inspection WHERE id = ?',
      variables: [Variable.withString(id)],
    ).get();
    if (rows.isEmpty) return null;
    final bytes = rows.first.data['bytes'];
    if (bytes == null) return null;
    if (bytes is Uint8List) return bytes;
    if (bytes is List<int>) return Uint8List.fromList(bytes);
    return null;
  }

  /// Builds a record from one raw row; null when the row cannot be read
  /// (missing id or unparseable time), so a bad row is skipped, not fatal.
  static LidInspectionRecord? recordFromRow(Map<String, Object?> data) {
    final id = data['id'];
    final time = parseInspectionTime(data['time_text'] as String?);
    if (id is! String || time == null) return null;
    return LidInspectionRecord(
      id: id,
      camera: data['camera'] as String? ?? '',
      time: time,
      score: _double(data['score']),
      threshold: _double(data['threshold']),
      anomaly: _bool(data['anomaly']),
      armed: _bool(data['armed']),
      lidType: data['lid_type'] as String?,
      modelVersion: data['model_version'] as String?,
      inferenceMs: _int(data['inference_ms']),
      hasImage: _bool(data['has_image']),
    );
  }

  static double _double(Object? v) => switch (v) {
        num n => n.toDouble(),
        String s => double.tryParse(s) ?? 0,
        _ => 0,
      };

  static int? _int(Object? v) => switch (v) {
        int i => i,
        num n => n.toInt(),
        String s => int.tryParse(s),
        _ => null,
      };

  // SQLite returns booleans as 0/1 and Postgres as bool; both land here.
  static bool _bool(Object? v) => switch (v) {
        bool b => b,
        num n => n != 0,
        String s => s == 't' || s == 'true' || s == '1',
        _ => false,
      };
}
