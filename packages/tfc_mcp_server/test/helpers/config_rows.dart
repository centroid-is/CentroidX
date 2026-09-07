/// Seeding `config_item` the way the app writes it, for tests of the readers.
///
/// The configuration these tests hand to `ConfigService` used to be three JSON
/// blobs in `flutter_preferences`. It is rows now — one per page, one per
/// top-level asset, one per key mapping, one per preference — so a fixture
/// that seeds the blob is seeding something nothing reads. That is a test
/// that passes by describing a plant which no longer exists, which is the
/// failure mode the cutover is most exposed to, so the seeding lives in one
/// place rather than being re-derived per file.
///
/// `config_item` is created by tfc_dart's migration and is deliberately not
/// part of `ServerDatabase`'s drift schema — one physical table with more than
/// one Dart schema over it, the same arrangement `flutter_preferences` has. So
/// [createConfigItemTable] creates it with DDL, the way a real database gets
/// it, and a test that wants the *un*migrated database simply never calls it.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

/// `config_item`, matching tfc_dart's migration.
Future<void> createConfigItemTable(GeneratedDatabase db) => db.customStatement(
    'CREATE TABLE IF NOT EXISTS config_item (kind TEXT NOT NULL, '
    'id TEXT NOT NULL, scope TEXT NOT NULL, parent_id TEXT, '
    'sort_index INTEGER, payload TEXT NOT NULL, '
    'rev INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL, '
    'updated_by TEXT NOT NULL, PRIMARY KEY (kind, id, scope))');

/// One row, payload encoded.
Future<void> insertConfigRow(
  GeneratedDatabase db, {
  required String kind,
  required String id,
  required Object? payload,
  String scope = 'shared',
  String? parentId,
  int? sortIndex,
}) =>
    db.customStatement(
      'INSERT INTO config_item (kind, id, scope, parent_id, sort_index, '
      'payload, rev, updated_at, updated_by) VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)',
      [
        kind,
        id,
        scope,
        parentId,
        sortIndex,
        jsonEncode(payload),
        '2026-09-07T00:00:00Z',
        'tester',
      ],
    );

/// [pages], keyed by page id, as page rows plus one asset row per entry of
/// each page's `assets` list.
///
/// The split `page_codec.dart` makes: the page's own JSON goes in the page
/// row, and each top-level asset becomes a row carrying the page's id in
/// `parent_id` and its position in `sort_index`. Which page an asset belongs
/// to and what order it paints in are columns now, not list position, and a
/// fixture that did not split them would never exercise the reassembly.
///
/// The pages map a reader gets back is keyed by `menu_item.path`, so give each
/// page one unless the test is about the slug fallback.
Future<void> seedPages(
  GeneratedDatabase db,
  Map<String, Map<String, dynamic>> pages,
) async {
  await createConfigItemTable(db);
  for (final entry in pages.entries) {
    final page = entry.value;
    final assets = (page['assets'] as List?) ?? const [];
    await insertConfigRow(
      db,
      kind: 'page',
      id: entry.key,
      payload: {...page}..remove('assets'),
    );
    for (var index = 0; index < assets.length; index++) {
      await insertConfigRow(
        db,
        kind: 'asset',
        id: '${entry.key}/asset-$index',
        parentId: entry.key,
        sortIndex: index,
        payload: assets[index],
      );
    }
  }
}

/// A blob-shaped `{'nodes': {key: entry}}` fixture as the rows that replaced
/// it: one `key_mapping` row per key, the entry as its payload.
///
/// Every value has to be one `KeyMappingEntry.fromJson` accepts. Reading the
/// blob was a bare `jsonDecode` and validated nothing; reading the rows goes
/// through the codec, which is the free validation it was adopted for — so a
/// fixture with an invented enum value now fails here rather than describing a
/// mapping the plant could not hold.
Future<void> seedKeyMappings(
  GeneratedDatabase db,
  Map<String, dynamic> blob,
) async {
  await createConfigItemTable(db);
  final nodes = (blob['nodes'] as Map).cast<String, dynamic>();
  for (final entry in nodes.entries) {
    await insertConfigRow(db,
        kind: 'key_mapping', id: entry.key, payload: entry.value);
  }
}

/// One shared `preference` row — `alarm_man_config` and its like.
///
/// Plan 04-11 migrates the preferences; until it has, production reads null
/// here and so does a test that does not call this.
Future<void> seedPreferenceRow(
  GeneratedDatabase db,
  String key,
  Object? value,
) async {
  await createConfigItemTable(db);
  await insertConfigRow(db, kind: 'preference', id: key, payload: value);
}
