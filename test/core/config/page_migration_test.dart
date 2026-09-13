/// The pages migration's cheap lane, and the owner of the integration
/// fixture.
///
/// `blob_migration_test.dart` in `tfc_dart` proves the machinery — the gate,
/// the sort keys, the marker last, a parse that throws — against a synthetic
/// parser. What can only be proved *here* is that the parser this migration
/// actually injects is the page codec, and that what it produces is what the
/// rows must hold: page ids derived from paths, asset parents that are page
/// ids rather than paths, and a layout that comes back out of the items
/// unchanged.
///
/// The advisory lock is not here and cannot be — sqlite has no such statement
/// — and lives in `packages/tfc_dart/test/integration/page_migration_test.dart`.
/// That suite cannot import this one's codec (it is Flutter's, `tfc_dart` has
/// none), so **this file generates the fixture it reads** and fails if the
/// checked-in copy has gone stale. See `the integration fixture` group.
///
/// ## Running it against the real blob
///
/// Production `page_editor_data` is 145 kB of plant layout and is not
/// committed. Point the test at a dump instead with
///
///     CENTROIDX_PAGE_EDITOR_BLOB=/path/to/page_editor_data.json flutter test
///
/// and the same assertions run over it — 9 pages and 196 assets, on the
/// August snapshot.
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:tfc/core/config/page_codec.dart';
import 'package:tfc/core/config/page_migration.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc_dart/core/config/blob_migration.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart' show kPagesMigratedMarkerId;
import 'package:tfc_dart/core/config/sort_keys.dart';
import 'package:tfc_dart/core/database_drift.dart';

/// Environment variable naming a real `page_editor_data` dump.
const String _realBlobEnv = 'CENTROIDX_PAGE_EDITOR_BLOB';

/// Set to `1` to rewrite the integration fixture from this run's output.
const String _regenEnv = 'CENTROIDX_REGEN_FIXTURES';

/// The fixture `packages/tfc_dart/test/integration/page_migration_test.dart`
/// runs against, relative to the repository root.
const String _fixturePath =
    'packages/tfc_dart/test/integration/fixtures/page_blob_fixture.json';

/// Two pages and a section page with no assets, with two assets identical but
/// for their position — the pair that makes the derived id's index component
/// load-bearing.
const String _fixtureBlob = '''
{
  "/": {
    "menu_item": {"label": "Home", "path": "/", "icon": "home", "children": []},
    "assets": [
      {
        "asset_name": "LEDConfig",
        "coordinates": {"x": 0.1, "y": 0.1, "angle": null},
        "size": {"width": 0.03, "height": 0.03},
        "text": "Run",
        "textPos": "right",
        "key": "CN04.Run",
        "on_color": {"role": "green"},
        "off_color": {"role": "grey"},
        "led_type": "circle"
      },
      {
        "asset_name": "LEDConfig",
        "coordinates": {"x": 0.2, "y": 0.1, "angle": null},
        "size": {"width": 0.03, "height": 0.03},
        "text": "Run",
        "textPos": "right",
        "key": "CN04.Run",
        "on_color": {"role": "green"},
        "off_color": {"role": "grey"},
        "led_type": "circle"
      },
      {
        "asset_name": "LEDConfig",
        "coordinates": {"x": 0.3, "y": 0.1, "angle": null},
        "size": {"width": 0.03, "height": 0.03},
        "text": "Stop",
        "textPos": "right",
        "key": "CN04.Stop",
        "on_color": {"role": "red"},
        "off_color": {"role": "grey"},
        "led_type": "circle"
      }
    ],
    "mirroring_disabled": false,
    "navigation_priority": 0
  },
  "/diagnostics": {
    "menu_item": {
      "label": "Diagnostics", "path": "/diagnostics",
      "icon": "build", "children": []
    },
    "assets": [],
    "mirroring_disabled": true,
    "navigation_priority": 5
  }
}
''';

late AppDatabase db;

Future<List<ConfigItemRow>> rows() => db.select(db.configItemTable).get();
Future<List<ConfigChangeRow>> changes() =>
    db.select(db.configChangeTable).get();

Future<void> seedBlob(String blob) =>
    db.into(db.flutterPreferences).insert(FlutterPreferencesCompanion.insert(
          key: kPageEditorPrefKey,
          value: Value(blob),
          type: 'String',
        ));

/// The copy body as the migration runs it: inside a transaction, with the lock
/// already held (there is nothing to hold here).
Future<MigrationOutcome> runCopy() =>
    db.transaction(() => copyPageBlobIntoRows(db));

/// Lines the package logger emitted while [body] ran.
Future<List<String>> logged(Future<void> Function() body) async {
  final lines = <String>[];
  void listener(OutputEvent event) => lines.addAll(event.lines);
  Logger.addOutputListener(listener);
  try {
    await body();
  } finally {
    Logger.removeOutputListener(listener);
  }
  return lines;
}

void main() {
  final realBlobPath = Platform.environment[_realBlobEnv];
  final blob = realBlobPath != null
      ? File(realBlobPath).readAsStringSync()
      : _fixtureBlob;
  final source = realBlobPath ?? 'the committed fixture';

  setUp(() => db = AppDatabase.inMemoryForTest());
  tearDown(() => db.close());

  group('what the injected parser produces, over $source', () {
    test('pages are named by derivedPageId and assets parent onto that id',
        () {
      final pages = PageManager.pagesFromJson(blob);
      final items = pageItemsFromBlob(blob);

      final pageItems =
          items.where((i) => i.kind == ConfigKind.page).toList();
      expect(pageItems, hasLength(pages.length));
      expect(
        {for (final i in pageItems) i.id},
        {for (final path in pages.keys) derivedPageId(path)},
        reason: 'the migration is the one moment a page id may be derived; '
            'every other caller mints a random one',
      );

      final pageIds = {for (final i in pageItems) i.id};
      final assets = items.where((i) => i.kind == ConfigKind.asset);
      expect(assets.every((a) => pageIds.contains(a.parentId)), isTrue,
          reason: 'a parent that was a path would go stale the first time '
              'somebody renamed the page');
      expect(assets.map((a) => a.id).toSet(), hasLength(assets.length),
          reason: 'two assets colliding on a derived id would silently lose '
              'one of them');
    });

    test('the layout round-trips through the items', () {
      final items = pageItemsFromBlob(blob);
      final back = pagesOf(items);

      expect(back.keys.toSet(), PageManager.pagesFromJson(blob).keys.toSet());
      // Against the codec's own round trip rather than a re-implementation of
      // it: what is under test here is the migration's parser, and
      // `page_codec_test.dart` owns the codec's correctness.
      expect(pageBlobOf(items), pageBlobOf(pageItemsFromBlob(blob)));
      expect(
        back.values.fold(0, (int sum, page) => sum + page.assets.length),
        PageManager.pagesFromJson(blob)
            .values
            .fold(0, (int sum, page) => sum + page.assets.length),
      );
    });
  });

  group('the copy body against sqlite, over $source', () {
    test('every page and asset becomes a row, keyed (i+1)*1024 per page',
        () async {
      await seedBlob(blob);

      late MigrationOutcome outcome;
      final lines = await logged(() async {
        outcome = await runCopy();
      });
      expect(outcome, MigrationOutcome.migrated);

      final pages = PageManager.pagesFromJson(blob);
      final assetCount = topLevelAssets(pages).length;
      final stored = await rows();
      expect(
          stored.where((r) => r.kind == ConfigKind.page.wireName).length,
          pages.length);
      expect(
          stored.where((r) => r.kind == ConfigKind.asset.wireName).length,
          assetCount);

      // Per page, the keys are the gapped ones and nothing else: this is what
      // the first post-migration save diffs against, and a key the store
      // would not have produced makes every asset on the page look edited.
      final byParent = <String, List<ConfigItemRow>>{};
      for (final r
          in stored.where((r) => r.kind == ConfigKind.asset.wireName)) {
        (byParent[r.parentId!] ??= []).add(r);
      }
      for (final group in byParent.values) {
        final keys = group.map((r) => r.sortIndex!).toList()..sort();
        expect(keys, [
          for (var i = 0; i < group.length; i++) (i + 1) * kSortKeyGap,
        ]);
      }
      expect(
          stored
              .where((r) => r.kind == ConfigKind.page.wireName)
              .every((r) => r.sortIndex == null),
          isTrue);

      expect(
        lines.join('\n'),
        contains('pages migration: ${pages.length} pages, $assetCount assets'),
        reason: 'the line an engineer reads before agreeing to a cutover, and '
            'it has to be logged before anything is written',
      );

      // Rollback insurance: Phase 4 drops the blob, not this.
      expect(
          await (db.select(db.flutterPreferences)
                ..where((t) => t.key.equals(kPageEditorPrefKey)))
              .getSingleOrNull(),
          isNotNull);
    });

    test('the marker is written, shared and underscore-prefixed', () async {
      await seedBlob(blob);
      expect(await runCopy(), MigrationOutcome.migrated);

      final marker = (await rows()).singleWhere(
          (r) => r.kind == ConfigKind.preference.wireName);
      expect(marker.id, kPagesMigratedMarkerId);
      expect(marker.scope, ConfigScope.shared.wireName);
    });

    test('a second run writes nothing', () async {
      await seedBlob(blob);
      expect(await runCopy(), MigrationOutcome.migrated);
      final before = (await rows()).length;
      final logBefore = (await changes()).length;

      expect(await runCopy(), MigrationOutcome.alreadyDone);

      expect((await rows()).length, before);
      expect((await changes()).length, logBefore);
    });

    test('page rows already present are not enough: the marker is the gate',
        () async {
      await seedBlob(blob);
      await db.into(db.configItemTable).insert(ConfigItemTableCompanion.insert(
            kind: ConfigKind.page.wireName,
            id: 'a page somebody else left behind',
            scope: ConfigScope.shared.wireName,
            payload: '{}',
            updatedAt: DateTime.utc(2026, 1, 1),
            updatedBy: 'another station',
          ));

      expect(await runCopy(), MigrationOutcome.migrated);
      expect(await changes(), isNotEmpty);
      expect((await rows()).map((r) => r.id), contains(kPagesMigratedMarkerId));
    });

    test('a plant with no page_editor_data row is noBlob, and gets the marker',
        () async {
      expect(await runCopy(), MigrationOutcome.noBlob);
      expect((await rows()).map((r) => r.id), [kPagesMigratedMarkerId],
          reason: 'looked at and found nothing; the sweep and the preference '
              'migration both read the marker to tell that from "not yet"');
      expect(await runCopy(), MigrationOutcome.alreadyDone);
    });

    test('an unrecognisable blob throws and leaves nothing behind', () async {
      await seedBlob('not json at all');

      await expectLater(runCopy(), throwsA(isA<FormatException>()));
      expect(await rows(), isEmpty);
      expect(await changes(), isEmpty);
    });
  });

  group('the integration fixture', () {
    test('$_fixturePath is what this codec produces today', () {
      // `tfc_dart` has no Flutter and therefore no page codec, so its
      // integration suite cannot build page payloads. It reads them from a
      // file, and this is the only thing that keeps that file honest: an
      // AssetPage schema change fails HERE, with the command to fix it,
      // instead of silently rotting a suite that then proves nothing about
      // the payloads a station would actually write.
      final items = pageItemsFromBlob(_fixtureBlob);
      final generated = const JsonEncoder.withIndent('  ').convert({
        'blob': pageBlobOf(items),
        'items': [
          for (final item in items)
            {
              'kind': item.kind.wireName,
              'id': item.id,
              'scope': item.scope.wireName,
              'parent_id': item.parentId,
              'sort_index': item.sortIndex,
              'payload': item.payload,
            }
        ],
      });

      final file = File(_fixturePath);
      if (Platform.environment[_regenEnv] == '1') {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('$generated\n');
        return;
      }

      expect(file.existsSync(), isTrue,
          reason: 'regenerate it with $_regenEnv=1 flutter test '
              'test/core/config/page_migration_test.dart');
      expect(
        file.readAsStringSync(),
        '$generated\n',
        reason: 'the fixture the tfc_dart integration suite reads no longer '
            'matches what the codec produces. Regenerate it with:\n'
            '  $_regenEnv=1 flutter test '
            'test/core/config/page_migration_test.dart',
      );
    });
  });
}
