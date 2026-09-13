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
/// one Dart schema over it. So [createConfigItemTable] creates it with DDL,
/// the way a real database gets it, and a test that wants the *un*migrated
/// database simply never calls it.
///
/// [createFlutterPreferencesTable] is here for the opposite reason: the
/// retired table has no Dart schema in this package at all any more, and the
/// tests that still want it want to prove it is ignored.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:tfc_dart/tfc_dart_core.dart' show canonicalJson;

/// `config_item`, matching tfc_dart's migration.
Future<void> createConfigItemTable(GeneratedDatabase db) => db.customStatement(
    'CREATE TABLE IF NOT EXISTS config_item (kind TEXT NOT NULL, '
    'id TEXT NOT NULL, scope TEXT NOT NULL, parent_id TEXT, '
    'sort_index INTEGER, payload TEXT NOT NULL, '
    'rev INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL, '
    'updated_by TEXT NOT NULL, PRIMARY KEY (kind, id, scope))');

/// `flutter_preferences`, the retired table, matching what a plant still
/// physically carries until somebody runs the drop tool.
///
/// Created with DDL because this package no longer has a drift schema for it:
/// the MCP server stopped reading the table, and the table class went with the
/// read. A schema this package does not need is a schema that invites the read
/// back. Tests seed it here to prove the readers ignore it, which is a claim
/// that only means anything against a database where the table really exists.
Future<void> createFlutterPreferencesTable(GeneratedDatabase db) =>
    db.customStatement(
        'CREATE TABLE IF NOT EXISTS flutter_preferences (key TEXT NOT NULL '
        'PRIMARY KEY, value TEXT, type TEXT NOT NULL)');

/// One `flutter_preferences` row, JSON-encoding [value] the way the app did.
///
/// Creates the table first, so a test that seeds a blob does not also have to
/// remember that nothing else will.
Future<void> insertFlutterPreferenceRow(
  GeneratedDatabase db, {
  required String key,
  required Object? value,
  String type = 'String',
}) async {
  await createFlutterPreferencesTable(db);
  await db.customStatement(
    'INSERT INTO flutter_preferences (key, value, type) VALUES (?, ?, ?)',
    [key, jsonEncode(value), type],
  );
}

/// `config_change`, matching tfc_dart's migration.
///
/// Only the consistency check reads this table, and only tests of it need the
/// table to exist: a fixture that seeds `config_item` alone is a database no
/// station has ever written to, which is exactly what the check reports.
Future<void> createConfigChangeTable(GeneratedDatabase db) =>
    db.customStatement('CREATE TABLE IF NOT EXISTS config_change ('
        'id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, '
        'action_id TEXT NOT NULL, who TEXT NOT NULL, station TEXT NOT NULL, '
        'role_name TEXT NOT NULL, reason TEXT, kind TEXT NOT NULL, '
        'entity_id TEXT NOT NULL, scope TEXT NOT NULL, op TEXT NOT NULL, '
        'old_value TEXT, new_value TEXT)');

/// One change row. [newValue] is the whole entity — `{parent_id, sort_index,
/// payload}` — never the bare payload, because that is what the column holds
/// and what the consistency check compares against.
Future<void> insertConfigChangeRow(
  GeneratedDatabase db, {
  required String kind,
  required String id,
  required String? newValue,
  String scope = 'shared',
  String op = 'insert',
}) =>
    db.customStatement(
      'INSERT INTO config_change (at, action_id, who, station, role_name, '
      'kind, entity_id, scope, op, new_value) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        '2026-09-07T00:00:00Z',
        'action-1',
        'tester',
        'test-station',
        'Engineering',
        kind,
        id,
        scope,
        op,
        newValue,
      ],
    );

/// The change row a correct write of this item would have left: the entity,
/// canonically encoded, position included.
String entityOf(
  Object? payload, {
  String? parentId,
  int? sortIndex,
}) =>
    canonicalJson({
      'parent_id': parentId,
      'sort_index': sortIndex,
      'payload': payload,
    });

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

/// One shared `preference` row — `alarm_man_config` and its like — **in the
/// envelope production writes**: `{"type": "String", "value": "<json>"}`, the
/// shape `SharedRowPreferences` and the preference migration both store.
///
/// The envelope is not optional here. The fixtures used to insert the bare
/// document, and every MCP test passed against a shape no row ever held —
/// while on a migrated plant the service handed the envelope back as the
/// document and reported zero alarms.
Future<void> seedPreferenceRow(
  GeneratedDatabase db,
  String key,
  Object? value,
) async {
  await createConfigItemTable(db);
  await insertConfigRow(db,
      kind: 'preference',
      id: key,
      payload: {'type': 'String', 'value': jsonEncode(value)});
}
