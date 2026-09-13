/// The generic half of the blob→rows migration, everything decidable without
/// a Postgres server.
///
/// `key_mapping_migration_unit_test.dart` proves the same machinery through
/// the key-mappings caller and is the regression proof that hoisting it here
/// changed nothing. What this file adds is the two things the key-mappings
/// caller cannot exercise, because its blob has neither:
///
///   * a parse that **throws** — the transaction unwinds and the marker never
///     lands, which is what a station losing power mid-copy leaves behind;
///   * items that carry a **sort index** — pages and assets do, key mappings
///     do not, and the keys the migration writes are what the first
///     post-migration save diffs against.
///
/// The lock itself is not here and cannot be: sqlite has no advisory locks.
/// `test/integration/page_migration_test.dart` holds that half.
@TestOn('vm')
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/blob_migration.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/sort_keys.dart';
import 'package:tfc_dart/core/database_drift.dart';

/// Stands in for the page blob: the string is never parsed by anything real
/// here, the parser under test is [_parse].
const String _blob = '{"pages": "whatever the codec would read"}';

const String _prefKey = 'page_editor_data';
const String _markerId = '_migrated.pages';

late AppDatabase db;

Future<List<ConfigItemRow>> items() => db.select(db.configItemTable).get();
Future<List<ConfigChangeRow>> changes() =>
    (db.select(db.configChangeTable)..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();

Future<void> seedBlob(String blob) =>
    db.into(db.flutterPreferences).insert(FlutterPreferencesCompanion.insert(
          key: _prefKey,
          value: Value(blob),
          type: 'String',
        ));

/// One page with three assets, in the shape the page codec emits: the page
/// item carries no sort index (pages are a set), the assets carry **ordinals**
/// 0, 1, 2 — which is what makes the stored keys observable.
List<ConfigItem> _parse(String blob) => [
      ConfigItem.of(kind: ConfigKind.page, id: 'p1', value: {'path': '/roe'}),
      for (var i = 0; i < 3; i++)
        ConfigItem.of(
          kind: ConfigKind.asset,
          id: 'a$i',
          value: {'asset_name': 'LEDConfig', 'n': i},
          parentId: 'p1',
          sortIndex: i,
        ),
    ];

/// The copy body as the migration runs it: inside a transaction, with the lock
/// already held (there is nothing to hold here).
Future<MigrationOutcome> runCopy({
  BlobParser parse = _parse,
  Set<ConfigKind> kinds = const {ConfigKind.page, ConfigKind.asset},
  bool Function(ConfigItemRow row)? isPlaceholder,
}) =>
    db.transaction(() => copyBlobIntoRowsLocked(
          db,
          prefKey: _prefKey,
          markerId: _markerId,
          kinds: kinds,
          parse: parse,
          label: 'pages',
          isPlaceholder: isPlaceholder,
        ));

/// The seed a migration may find in front of it: `p1` as a placeholder at
/// the seed's revision.
bool _seedP1(ConfigItemRow row) => row.id == 'p1' && row.rev <= 1;

void main() {
  setUp(() => db = AppDatabase.inMemoryForTest());
  tearDown(() => db.close());

  group('a parse that throws', () {
    test('leaves no rows, no change rows and no marker', () async {
      await seedBlob(_blob);

      await expectLater(
        runCopy(parse: (_) => throw const FormatException('unreadable')),
        throwsA(isA<FormatException>()),
      );

      expect(await items(), isEmpty);
      expect(await changes(), isEmpty,
          reason: 'the parse runs inside the transaction, so its throw '
              'unwinds the copy rather than half-writing it');
    });
  });

  group('the gate, generalised to a set of kinds', () {
    test('a row of a kind in kinds is not proof the migration ran — and not '
        'a licence to copy over it either', () async {
      await seedBlob(_blob);
      // A row a station wrote, or a rolled-back copy left behind. Reading it
      // as "the migration ran" is how a plant's real configuration stayed in
      // the blob forever, silently — see `_alreadyMigrated`'s doc. Reading
      // it as nothing and copying over it is how weeks of edits on rows were
      // reverted to cutover day. So it is neither: the copy stops, writes
      // nothing, and says so.
      await db.into(db.configItemTable).insert(ConfigItemTableCompanion.insert(
            kind: ConfigKind.asset.wireName,
            id: 'someone-elses-asset',
            scope: ConfigScope.shared.wireName,
            payload: '{}',
            updatedAt: DateTime.utc(2026, 1, 1),
            updatedBy: 'someone else',
          ));

      expect(await runCopy(), MigrationOutcome.rowsWithoutMarker);
      expect(await changes(), isEmpty);
      final rows = await items();
      expect(rows.map((r) => r.id), ['someone-elses-asset'],
          reason: 'a row the blob does not name is not this migration\'s to '
              'remove');
    });

    test('a placeholder row the blob names is overwritten, logged as an '
        'update, rev bumped', () async {
      await seedBlob(_blob);
      // The seed: same identity as a blob item, placeholder content, rev 1 —
      // and named as the placeholder, which is what lets the copy proceed
      // over it at all.
      await db.into(db.configItemTable).insert(ConfigItemTableCompanion.insert(
            kind: ConfigKind.page.wireName,
            id: 'p1',
            scope: ConfigScope.shared.wireName,
            payload: '{"seeded":true}',
            rev: const Value(1),
            updatedAt: DateTime.utc(2026, 1, 1),
            updatedBy: 'a station that could not see the blob',
          ));

      expect(await runCopy(isPlaceholder: _seedP1), MigrationOutcome.migrated);

      final p1 = (await items()).singleWhere((r) => r.id == 'p1');
      expect(p1.payload, isNot(contains('seeded')),
          reason: 'the blob is the plant\'s configuration; the seed is a '
              'placeholder');
      expect(p1.rev, 2,
          reason: 'carried forward and bumped, so a station holding rev 1 '
              'loses its next compare-and-swap rather than matching');
      final log = (await changes()).where((c) => c.entityId == 'p1').single;
      expect(log.op, 'update');
      expect(log.oldValue, contains('seeded'));
    });

    test('rows that are not the seed, with no marker, refuse the copy: '
        'nothing written, no marker, the plant stays on its rows', () async {
      // Weeks of relational edits on `p1` and a blob nobody has written to
      // since cutover day. The marker is missing — deleted by hand, or the
      // rows were written by a build whose gate never wrote one. Copying
      // would revert the edits and resurrect every deleted page; refusing
      // to copy a plant that never migrated would strand it. Neither guess
      // is made.
      await seedBlob(_blob);
      await db.into(db.configItemTable).insert(ConfigItemTableCompanion.insert(
            kind: ConfigKind.page.wireName,
            id: 'p1',
            scope: ConfigScope.shared.wireName,
            payload: '{"edited":"on the rows"}',
            rev: const Value(7),
            updatedAt: DateTime.utc(2026, 6, 1),
            updatedBy: 'gudrun',
          ));

      expect(await runCopy(isPlaceholder: _seedP1),
          MigrationOutcome.rowsWithoutMarker,
          reason: 'p1 at revision 7 is not the placeholder');

      final rows = await items();
      expect(rows.map((r) => r.id), ['p1'],
          reason: 'nothing else from the blob landed beside it');
      expect(rows.single.payload, '{"edited":"on the rows"}');
      expect(rows.single.rev, 7);
      expect(await changes(), isEmpty);
      expect(rows.any((r) => r.id == _markerId), isFalse,
          reason: 'no marker either: the drop tool must keep refusing until '
              'somebody has decided which side is the plant');
    });

    test('a row the editor made — any revision, an id the blob does not '
        'name — refuses the copy too', () async {
      // The pages variant of the same state: an earlier build saved the
      // built-in Home page as rows (random id) and never wrote the marker.
      // The blob\'s copy of Home carries a derived id, so a copy would not
      // overwrite it but sit beside it — two pages at one path.
      await seedBlob(_blob);
      await db.into(db.configItemTable).insert(ConfigItemTableCompanion.insert(
            kind: ConfigKind.page.wireName,
            id: 'random-editor-id',
            scope: ConfigScope.shared.wireName,
            payload: '{"path":"/roe"}',
            rev: const Value(1),
            updatedAt: DateTime.utc(2026, 6, 1),
            updatedBy: 'a station',
          ));

      expect(await runCopy(isPlaceholder: _seedP1),
          MigrationOutcome.rowsWithoutMarker);
      expect((await items()).map((r) => r.id), ['random-editor-id']);
    });

    test('with no placeholder rule, any existing row refuses the copy',
        () async {
      await seedBlob(_blob);
      await db.into(db.configItemTable).insert(ConfigItemTableCompanion.insert(
            kind: ConfigKind.page.wireName,
            id: 'p1',
            scope: ConfigScope.shared.wireName,
            payload: '{"seeded":true}',
            rev: const Value(1),
            updatedAt: DateTime.utc(2026, 1, 1),
            updatedBy: 'somebody',
          ));

      expect(await runCopy(), MigrationOutcome.rowsWithoutMarker);
    });

    test('a row of another kind does not stand in the way', () async {
      await seedBlob(_blob);
      await db.into(db.configItemTable).insert(ConfigItemTableCompanion.insert(
            kind: ConfigKind.keyMapping.wireName,
            id: 'CN04.Belt.Speed',
            scope: ConfigScope.shared.wireName,
            payload: '{}',
            rev: const Value(9),
            updatedAt: DateTime.utc(2026, 1, 1),
            updatedBy: 'somebody',
          ));

      expect(await runCopy(), MigrationOutcome.migrated);
    });

    test('a blob holding one identity twice is unreadable, and unwinds',
        () async {
      await seedBlob(_blob);

      await expectLater(
        runCopy(parse: (_) => [_parse(_blob).first, _parse(_blob).first]),
        throwsA(isA<FormatException>()),
      );

      expect(await items(), isEmpty);
      expect(await changes(), isEmpty);
    });

    test('a row of a kind outside kinds is not', () async {
      await seedBlob(_blob);
      await db.into(db.configItemTable).insert(ConfigItemTableCompanion.insert(
            kind: ConfigKind.keyMapping.wireName,
            id: 'CN04.Belt.Speed',
            scope: ConfigScope.shared.wireName,
            payload: '{}',
            updatedAt: DateTime.utc(2026, 1, 1),
            updatedBy: 'the other migration',
          ));

      expect(await runCopy(), MigrationOutcome.migrated,
          reason: 'the key mappings migrating first must not make the pages '
              'migration believe it has already run');
    });

    test('the marker alone is enough, for a plant with no pages', () async {
      await seedBlob(_blob);
      await db.into(db.configItemTable).insert(ConfigItemTableCompanion.insert(
            kind: ConfigKind.preference.wireName,
            id: _markerId,
            scope: ConfigScope.shared.wireName,
            payload: '{"type":"String","value":"2026-01-01T00:00:00.000"}',
            updatedAt: DateTime.utc(2026, 1, 1),
            updatedBy: 'migration',
          ));

      expect(await runCopy(), MigrationOutcome.alreadyDone);
      expect(await items(), hasLength(1));
    });

    test('a marker of a different migration is not this one', () async {
      await seedBlob(_blob);
      await db.into(db.configItemTable).insert(ConfigItemTableCompanion.insert(
            kind: ConfigKind.preference.wireName,
            id: '_migrated.key_mappings',
            scope: ConfigScope.shared.wireName,
            payload: '{"type":"String","value":"2026-01-01T00:00:00.000"}',
            updatedAt: DateTime.utc(2026, 1, 1),
            updatedBy: 'migration',
          ));

      expect(await runCopy(), MigrationOutcome.migrated);
    });
  });

  group('the copy body', () {
    test('ordinals become gapped stored keys, and nulls are left alone',
        () async {
      await seedBlob(_blob);
      expect(await runCopy(), MigrationOutcome.migrated);

      final rows = await items();
      final assets = {
        for (final r in rows.where((r) => r.kind == ConfigKind.asset.wireName))
          r.id: r.sortIndex
      };
      expect(assets, {
        'a0': kSortKeyGap,
        'a1': 2 * kSortKeyGap,
        'a2': 3 * kSortKeyGap,
      }, reason: 'assignSortKeys(parsed, {}) — one implementation of the first '
          'keys, so the first save after the migration diffs empty');

      final page =
          rows.singleWhere((r) => r.kind == ConfigKind.page.wireName);
      expect(page.sortIndex, isNull,
          reason: 'a page carries no ordinal; a null key means "this kind is '
              'a set" and must survive the migration as null');
      expect(page.parentId, isNull);

      final assetRows =
          rows.where((r) => r.kind == ConfigKind.asset.wireName).toList();
      expect(assetRows.map((r) => r.parentId).toSet(), {'p1'});
      expect(rows.map((r) => r.rev).toSet(), {1});
    });

    test('the payload is the parser\'s, byte for byte', () async {
      await seedBlob(_blob);
      expect(await runCopy(), MigrationOutcome.migrated);

      final rows = await items();
      final stored = {
        for (final r in rows.where((r) => r.kind != 'preference'))
          r.id: r.payload
      };
      expect(stored, {for (final i in _parse(_blob)) i.id: i.payload},
          reason: 'a re-encoded payload diffs as an edit on every station at '
              'the first reconcile after the cutover');
    });

    test('one change row per item, and none for the marker', () async {
      await seedBlob(_blob);
      expect(await runCopy(), MigrationOutcome.migrated);

      final log = await changes();
      expect(log, hasLength(4));
      expect(log.map((c) => c.entityId).toSet(), {'p1', 'a0', 'a1', 'a2'});
      expect(log.map((c) => c.actionId).toSet(), hasLength(1));
      expect(log.map((c) => c.kind).toSet(), {'page', 'asset'});
      expect(log.map((c) => c.who).toSet(), {'migration'});
    });

    test('the marker is the last row the copy writes', () async {
      await seedBlob(_blob);
      expect(await runCopy(), MigrationOutcome.migrated);

      // Insertion order, read straight off sqlite's rowid. Structurally the
      // marker is the last statement of the copy body and the body runs inside
      // one transaction, but "last" is the property every station's first
      // sweep after the cutover depends on — 03-01's per-kind marker guard
      // refuses page rows on a sweep that finds no marker — so it is asserted
      // rather than left to the reader of the source.
      final order = await db
          .customSelect('SELECT id FROM config_item ORDER BY rowid')
          .map((row) => row.read<String>('id'))
          .get();
      expect(order.last, _markerId);
      expect(order, hasLength(5));
    });

    test('the marker is written, and the source blob is left in place',
        () async {
      await seedBlob(_blob);
      expect(await runCopy(), MigrationOutcome.migrated);

      final rows = await items();
      final marker = rows
          .singleWhere((r) => r.kind == ConfigKind.preference.wireName);
      expect(marker.id, _markerId);
      expect(marker.scope, ConfigScope.shared.wireName);

      expect(
          await (db.select(db.flutterPreferences)
                ..where((t) => t.key.equals(_prefKey)))
              .getSingleOrNull(),
          isNotNull,
          reason: 'the blob is Phase 4\'s to drop, not this migration\'s');
    });

    test('no blob at all is noBlob, and writes the marker alone', () async {
      expect(await runCopy(), MigrationOutcome.noBlob);
      final rows = await items();
      expect(rows.map((r) => r.id), [_markerId],
          reason: 'a plant that never stored this blob has been looked at, '
              'and the marker is what says so: without it every sweep '
              'against a legitimately empty remote is refused and the '
              'preference migration never runs');
      expect(await changes(), isEmpty);

      expect(await runCopy(), MigrationOutcome.alreadyDone);
    });

    test('a second run writes nothing', () async {
      await seedBlob(_blob);
      expect(await runCopy(), MigrationOutcome.migrated);
      final before = await items();

      expect(await runCopy(), MigrationOutcome.alreadyDone);

      expect((await items()).length, before.length);
      expect(await changes(), hasLength(4));
    });
  });
}
