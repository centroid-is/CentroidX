/// The other half of the migration's safety net.
///
/// A key mapping that does not survive the split stops resolving; a page or an
/// asset that does not survive it disappears off the mimic. Neither says why.
/// So the split is asserted to preserve the layout structurally, and the
/// derived-id scheme is asserted to be stable — because the thing that would
/// actually go wrong at 6 a.m. on cutover day is two stations migrating the
/// same blob and writing every asset twice.
///
/// ## Running it against the real blob
///
/// The committed fixture is representative, not real: production
/// `page_editor_data` is 145 kB of plant layout and does not belong in the
/// repository. Point the test at a real dump instead with
///
///     CENTROIDX_PAGE_EDITOR_BLOB=/path/to/page_editor_data.json flutter test
///
/// and the same assertions run over it.
///
/// **The dump must be the raw blob and nothing else.** This test hands the
/// file straight to `PageManager.pagesFromJson`, so what it needs is a single
/// JSON value:
///
///     psql -Atc "SELECT value FROM flutter_preferences WHERE key='page_editor_data'"
///
/// `-A` and `-t` are what make that true -- unaligned, no header, no row
/// count. `tools/svn_apply_config.py --backup-only` does **not** produce this:
/// it writes a three-column `key,value,type` CSV of the whole table, with a
/// header line, and `pagesFromJson` throws on that header. The full form,
/// with the ssh hop and the container lookup, is in
/// `docs/relational-config-cutover-runbook.md` section 1.
library;

import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/config/page_codec.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/assets/common.dart'
    show Coordinates, RelativeSize;
import 'package:tfc/page_creator/assets/led.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc_dart/core/config/config_diff.dart';
import 'package:tfc_dart/core/config/config_item.dart';

/// Environment variable naming a real `page_editor_data` dump.
const String _realBlobEnv = 'CENTROIDX_PAGE_EDITOR_BLOB';

/// Two pages, an empty section page, a composite asset with subdevices, and
/// two assets identical but for their position — the last of which is what
/// makes the derived id's index component load-bearing.
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
        "asset_name": "BeckhoffCX5010Config",
        "coordinates": {"x": 0.5, "y": 0.6, "angle": null},
        "size": {"width": 0.5, "height": 0.5},
        "text": null,
        "textPos": null,
        "subdevices": [
          {
            "asset_name": "BeckhoffEL1008Config",
            "coordinates": {"x": 0.0, "y": 0.0, "angle": null},
            "size": {"width": 0.03, "height": 0.03},
            "text": null,
            "textPos": null,
            "nameOrId": "1",
            "descriptionsKey": null,
            "rawStateKey": null,
            "processedStateKey": null,
            "forceValuesKey": null,
            "onFiltersKey": null,
            "offFiltersKey": null
          }
        ]
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
    "navigation_priority": 5,
    "published": false
  }
}
''';

void main() {
  final realBlobPath = Platform.environment[_realBlobEnv];

  // The cutover gate must not be satisfiable by running nothing.
  //
  // Falling back to the committed fixture is right for everyday work, and
  // wrong for the one question the cutover asks: *has this suite run green
  // against current production data?* Without this guard that question is
  // answered green by a run that never opened a dump — the same vacuous-pass
  // defect `scripts/check-preferences-construction.sh` is armed against, and
  // the same one that script's header calls "the invariant that will rot
  // silently".
  //
  // Set CENTROIDX_REQUIRE_REAL_BLOB=1 in the cutover runbook. The group name
  // below prints the source, so the runbook can require the line naming the
  // dump file as its evidence.
  if (Platform.environment['CENTROIDX_REQUIRE_REAL_BLOB'] == '1' &&
      realBlobPath == null) {
    throw StateError('CENTROIDX_REQUIRE_REAL_BLOB=1 but $_realBlobEnv is not '
        'set: this run would have passed against the committed fixture and '
        'proved nothing about production data.');
  }

  final blob = realBlobPath != null
      ? File(realBlobPath).readAsStringSync()
      : _fixtureBlob;
  final source = realBlobPath ?? 'the committed fixture';

  group('page codec, over $source', () {
    test('every page and every top-level asset survives the split', () {
      final original = PageManager.pagesFromJson(blob);
      final expectedAssets =
          original.values.fold(0, (sum, page) => sum + page.assets.length);

      final items = pageItemsFromBlob(blob);
      final pageCount =
          items.where((i) => i.kind == ConfigKind.page).length;
      final assetCount =
          items.where((i) => i.kind == ConfigKind.asset).length;

      expect(pageCount, original.length);
      expect(assetCount, expectedAssets,
          reason: 'an asset that does not come back is one that vanishes off '
              'the mimic with nothing to say why');
    });

    test('blob -> items -> blob is the same layout', () {
      // Compared through the model on both sides, not byte for byte, for the
      // reason spelled out in `key_mapping_codec_test.dart`: every config
      // class's `toJson()` emits explicit nulls for unset optionals, so the
      // trip normalises. Production has stored the normalised form since the
      // first Save.
      //
      // The left side additionally gains an `id` on every asset that had none,
      // which is the migration doing its job — so ids are stripped from both
      // sides before comparing, and asserted separately below.
      final rebuilt = jsonDecode(pageBlobOf(pageItemsFromBlob(blob)));
      final viaModel = {
        for (final e in PageManager.pagesFromJson(blob).entries)
          e.key: e.value.toJson(),
      };

      expect(
        const DeepCollectionEquality().equals(
            canonicalise(_withoutAssetIds(rebuilt)),
            canonicalise(_withoutAssetIds(jsonDecode(jsonEncode(viaModel))))),
        isTrue,
        reason: 'the reassembled layout must hold exactly what the stored one '
            'did — this is what makes the cutover reversible',
      );
    });

    test('assets keep their page and their paint order', () {
      final original = PageManager.pagesFromJson(blob);
      final rebuilt = pagesOf(pageItemsFromBlob(blob));

      expect(rebuilt.keys.toSet(), original.keys.toSet());
      for (final path in original.keys) {
        expect(
          rebuilt[path]!.assets.map((a) => a.assetName).toList(),
          original[path]!.assets.map((a) => a.assetName).toList(),
          reason: 'paint order is configuration: losing it changes which '
              'asset is drawn on top of which, on page $path',
        );
      }
    });

    test('every asset item names its page and its position', () {
      for (final item in pageItemsFromBlob(blob)) {
        if (item.kind != ConfigKind.asset) continue;
        expect(item.parentId, isNotNull);
        expect(item.sortIndex, isNotNull);
        expect(item.scope, ConfigScope.shared);
      }
    });

    test('page items do not carry their assets', () {
      for (final item in pageItemsFromBlob(blob)) {
        if (item.kind != ConfigKind.page) continue;
        expect(item.decode().containsKey('assets'), isFalse,
            reason: 'an asset carried in two places is an asset that can '
                'disagree with itself');
      }
    });

    test('reading twice reports no change', () {
      final diff = diffConfigItems(
        stored: pageItemsFromBlob(blob),
        wanted: pageItemsFromBlob(blob),
      );
      expect(diff.isEmpty, isTrue,
          reason: 'or every boot would write and audit every asset');
    });
  });

  group('derived ids', () {
    test('two stations migrating the same blob agree on every id', () {
      // The failure this exists to prevent: `Asset.id` is null until something
      // links to the asset, several SVN stations share one Postgres and boot
      // at once, and a random mint would write every asset once per station.
      final a = pageItemsFromBlob(_fixtureBlob).map((i) => i.id).toList();
      final b = pageItemsFromBlob(_fixtureBlob).map((i) => i.id).toList();
      expect(a, b);
    });

    test('two identical assets on one page get different ids', () {
      // A row of identical drives is legitimate. Without the index in the
      // hash they would collide into one row and one of them would vanish.
      final ids = pageItemsFromBlob(_fixtureBlob)
          .where((i) => i.kind == ConfigKind.asset)
          .map((i) => i.id)
          .toList();
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('an asset that already has an id keeps it', () {
      final withId = jsonDecode(_fixtureBlob) as Map<String, dynamic>;
      ((withId['/'] as Map)['assets'] as List)[0]['id'] = 'deadbeefcafe0000feed';

      final items = pageItemsFromBlob(jsonEncode(withId));
      expect(
        items.where((i) => i.kind == ConfigKind.asset).map((i) => i.id),
        contains('deadbeefcafe0000feed'),
        reason: 'something already points at the asset by that name',
      );
    });

    test('a save mints random ids, so two editors do not collide', () {
      // The failure Fable's review caught in the first draft, where
      // `pageItems` derived ids on every save. Two people each adding a lamp
      // at the same index of the same page derive the *same* id from the same
      // content — and their two assets collapse into one row, which is the
      // exact failure rows exist to end. Derivation is a migration-only tool.
      final a = PageManager.pagesFromJson(_fixtureBlob);
      final b = PageManager.pagesFromJson(_fixtureBlob);

      final idsA =
          pageItems(a).where((i) => i.kind == ConfigKind.asset).map((i) => i.id);
      final idsB =
          pageItems(b).where((i) => i.kind == ConfigKind.asset).map((i) => i.id);

      expect(idsA.toSet().intersection(idsB.toSet()), isEmpty,
          reason: 'two independent saves of id-less assets must never agree '
              'on an id');
    });

    test('the migration derives, so two stations do agree', () {
      // The other side of the same coin, and why the flag exists at all.
      expect(
        pageItemsFromBlob(_fixtureBlob).map((i) => i.id).toList(),
        pageItemsFromBlob(_fixtureBlob).map((i) => i.id).toList(),
      );
    });

    test('an id survives a round trip through an old station', () {
      // Not a dual-write claim — the milestone rules dual-write out and does a
      // coordinated rollout instead. What this pins is narrower and still
      // load-bearing: the *current* code preserves ids it did not mint,
      // because `BaseAsset.id` is `@JsonKey(includeIfNull: false)` and so
      // round-trips when set and is absent when not. It is what makes the
      // compatibility blob safe to hand to a reader that has never heard of
      // ids, and if it ever changes, every migrated id is lost on the next
      // save that goes through the blob.
      final migrated = pageItemsFromBlob(_fixtureBlob);
      final ids = migrated
          .where((i) => i.kind == ConfigKind.asset)
          .map((i) => i.id)
          .toList();

      final reparsed = PageManager.pagesFromJson(pageBlobOf(migrated));
      final survived = [
        for (final page in reparsed.values)
          for (final asset in page.assets) asset.id,
      ];

      expect(survived.whereType<String>().toSet(), ids.toSet());
    });

    test('ids look like minted ones', () {
      // Nothing downstream should be able to tell a migrated id from one
      // `newAssetId()` produced: 24 lowercase hex characters.
      for (final items in [
        pageItemsFromBlob(_fixtureBlob),
        pageItems(PageManager.pagesFromJson(_fixtureBlob)),
      ]) {
        for (final item in items) {
          if (item.kind != ConfigKind.asset) continue;
          expect(item.id, matches(RegExp(r'^[0-9a-f]{24}$')));
        }
      }
    });
  });

  group('the diff is what a save writes', () {
    test('moving one asset is one changed item', () {
      final pages = PageManager.pagesFromJson(_fixtureBlob);
      final stored = pageItems(pages);

      final moved = PageManager.pagesFromJson(pageBlobOf(stored));
      moved['/']!.assets.first.coordinates.x = 0.42;

      final diff = diffConfigItems(stored: stored, wanted: pageItems(moved));

      expect(diff.changed, hasLength(1));
      expect(diff.changed.single.kind, ConfigKind.asset);
      expect(diff.added, isEmpty);
      expect(diff.removed, isEmpty);
    });

    test('unpublishing a page is one changed page and no assets', () {
      final pages = PageManager.pagesFromJson(_fixtureBlob);
      final stored = pageItems(pages);

      final edited = PageManager.pagesFromJson(pageBlobOf(stored));
      edited['/']!.published = false;

      final diff = diffConfigItems(stored: stored, wanted: pageItems(edited));

      expect(diff.changed, hasLength(1));
      expect(diff.changed.single.kind, ConfigKind.page);
      // The item is named by the page's minted id, not by '/' — the whole
      // point of the id, and the reason the edit found the same row after a
      // trip through the blob.
      expect(diff.changed.single.id, pages['/']!.id);
    });
  });

  group('page identity', () {
    test('a page item is named by the page id, not by its path', () {
      final pages = PageManager.pagesFromJson(_fixtureBlob);
      final items = pageItems(pages)
          .where((i) => i.kind == ConfigKind.page)
          .toList();

      expect(items.map((i) => i.id).toSet(),
          {pages['/']!.id, pages['/diagnostics']!.id});
      expect(items.map((i) => i.id), everyElement(isNot(startsWith('/'))),
          reason: 'a path-named row loses its history at every rename');
    });

    test('the minted id lands on the live page, not only in the row', () {
      // Same reason `pageItems` stamps asset ids on the live objects: an id
      // that exists only in the row means the next save mints a second one.
      final pages = PageManager.pagesFromJson(_fixtureBlob);
      expect(pages['/']!.id, isNull);

      pageItems(pages);

      expect(pages['/']!.id, isNotNull);
      expect(pages['/diagnostics']!.id, isNotNull);
    });

    test('an asset item names its page by id', () {
      final pages = PageManager.pagesFromJson(_fixtureBlob);
      final items = pageItems(pages);
      final parents = items
          .where((i) => i.kind == ConfigKind.asset)
          .map((i) => i.parentId)
          .toSet();

      expect(parents, {pages['/']!.id});
    });

    test('a rename is one changed page and zero changed assets', () {
      // SC-4's codec half. Path-keyed, renaming `/` would be a page DELETE
      // plus INSERT and an UPDATE of every asset on it: 4 change rows here,
      // 90 on `/roe` in production, for typing a name.
      final pages = PageManager.pagesFromJson(_fixtureBlob);
      final stored = pageItems(pages);

      final renamed = Map<String, AssetPage>.from(pages);
      final page = renamed.remove('/')!;
      renamed['/home'] =
          page.copyWith(menuItem: page.menuItem.copyWith(path: '/home'));

      final diff = diffConfigItems(stored: stored, wanted: pageItems(renamed));

      expect(diff.added, isEmpty);
      expect(diff.removed, isEmpty);
      expect(diff.changed, hasLength(1));
      expect(diff.changed.single.kind, ConfigKind.page);
      expect(diff.changed.single.id, page.id,
          reason: 'the row survives the rename, and so does its history');
    });

    test('a page id survives the editor undo round trip', () {
      // The undo stack is 50 encoded page-JSON strings and the save itself is
      // jsonEncode -> pagesFromJson, so an id held beside the object would be
      // gone at the first Ctrl+Z and the page that came back would be a
      // different row.
      final pages = PageManager.pagesFromJson(_fixtureBlob);
      pageItems(pages);
      final before = {for (final e in pages.entries) e.key: e.value.id};

      final undone = PageManager.copyPages(pages);

      expect({for (final e in undone.entries) e.key: e.value.id}, before);
      expect(
        pageItems(undone)
            .where((i) => i.kind == ConfigKind.page)
            .map((i) => i.id)
            .toSet(),
        before.values.toSet(),
        reason: 'a second mint after an undo would orphan every asset row',
      );
    });

    test('a page without an id serialises without the key', () {
      // `includeIfNull: false` is what keeps the field additive: a page saved
      // before ids existed round-trips exactly as it did.
      final pages = PageManager.pagesFromJson(_fixtureBlob);
      expect(pages['/']!.toJson().containsKey('id'), isFalse);
      expect(jsonDecode(pageBlobOf(pageItems(pages)))['/'],
          isA<Map<String, dynamic>>().having((m) => m['id'], 'id', isNotNull),
          reason: 'and once minted it rides along in the compatibility blob');
    });

    test('two stations migrating the same blob derive the same page ids', () {
      final a = pageItemsFromBlob(_fixtureBlob)
          .where((i) => i.kind == ConfigKind.page)
          .map((i) => i.id);
      final b = pageItemsFromBlob(_fixtureBlob)
          .where((i) => i.kind == ConfigKind.page)
          .map((i) => i.id);

      expect(a, b);
      expect(a, contains(derivedPageId('/')));
    });

    test('two independent saves mint different page ids', () {
      // SC-6 extended to pages. Deriving at save time would collapse two
      // editors' new pages into one row, exactly as it would for assets.
      final idsA = pageItems(PageManager.pagesFromJson(_fixtureBlob))
          .where((i) => i.kind == ConfigKind.page)
          .map((i) => i.id)
          .toSet();
      final idsB = pageItems(PageManager.pagesFromJson(_fixtureBlob))
          .where((i) => i.kind == ConfigKind.page)
          .map((i) => i.id)
          .toSet();

      expect(idsA.intersection(idsB), isEmpty);
    });

    test('page ids look like minted ones', () {
      for (final items in [
        pageItemsFromBlob(_fixtureBlob),
        pageItems(PageManager.pagesFromJson(_fixtureBlob)),
      ]) {
        for (final item in items.where((i) => i.kind == ConfigKind.page)) {
          expect(item.id, matches(RegExp(r'^[0-9a-f]{24}$')));
        }
      }
    });

    test('pagesOf keys by the payload path, so navigation is untouched', () {
      final rebuilt = pagesOf(pageItemsFromBlob(_fixtureBlob));
      expect(rebuilt.keys.toSet(), {'/', '/diagnostics'});
      expect(rebuilt['/diagnostics']!.menuItem.path, '/diagnostics');
    });

    test('two pages with empty paths do not collide on one key', () {
      // `pagesFromJson` slugs a key for a path-less page rather than letting
      // both land on ''. `pagesOf` has to do the same, or one of them is
      // silently overwritten by the other.
      final pages = PageManager.pagesFromJson(_fixtureBlob);
      pageItems(pages);
      final items = [
        for (final page in pages.values)
          ConfigItem.of(
            kind: ConfigKind.page,
            id: page.id!,
            value: pageFieldsOf(page.copyWith(
                menuItem: page.menuItem.copyWith(path: ''))),
          ),
      ];

      final rebuilt = pagesOf(items);

      expect(rebuilt, hasLength(2));
      for (final entry in rebuilt.entries) {
        expect(entry.value.menuItem.path, entry.key,
            reason: 'the generated key has to be written back into the '
                'payload, or the page disagrees with the map about where it '
                'lives');
      }
    });
  });

  group('rollout day: adopting the identities already on the rows', () {
    // Cutover day, in one function. Every station loaded its pages from the
    // blob before the migration ran, so the manager holds pages and assets
    // with no id at all — while the rows the migration just wrote hold the
    // derived ones. Minting fresh ids over that is ~410 removes and ~410 adds
    // that commit cleanly and sever every identity the migration made.
    //
    // What may NOT happen here is deriving an id: `derivedAssetId` is
    // migration-only, and computing one at save collapses two editors' new
    // assets into one row. Adoption only ever copies an id that is already on
    // a stored row.

    /// The rows the migration wrote from [blob].
    List<ConfigItem> migrated(String blob) => pageItemsFromBlob(blob);

    /// The same layout as the manager holds it after a blob fallback load:
    /// parsed by the app's own path, with no id anywhere.
    Map<String, AssetPage> fallback(String blob) =>
        PageManager.pagesFromJson(blob);

    test('every page and asset takes the id of the row it already is', () {
      final stored = migrated(_fixtureBlob);
      final pages = fallback(_fixtureBlob);
      expect(pages.values.every((p) => p.id == null), isTrue,
          reason: 'the fallback load mints nothing — that is the premise');

      adoptRowIdentities(pages, stored);

      final storedPageIds = {
        for (final item in stored)
          if (item.kind == ConfigKind.page)
            (item.decode()['menu_item'] as Map)['path'] as String: item.id,
      };
      for (final entry in pages.entries) {
        expect(entry.value.id, storedPageIds[entry.key],
            reason: 'the page at ${entry.key} must adopt its own row');
      }
      // And every asset, against the rows parented by that page.
      for (final entry in pages.entries) {
        final rows = [
          for (final item in stored)
            if (item.kind == ConfigKind.asset &&
                item.parentId == entry.value.id)
              item,
        ]..sort((a, b) => (a.sortIndex ?? 0).compareTo(b.sortIndex ?? 0));
        expect(entry.value.assets.map((a) => a.id).toList(),
            rows.map((r) => r.id).toList(),
            reason: 'assets on ${entry.key} adopt their rows in order');
      }
    });

    test('an adopted layout re-emits the stored items exactly', () {
      // The proof that matters: what `save()` would write after adoption is
      // byte-identical to what is stored, so the diff is empty and no row is
      // touched. Without adoption this is ~410 removes and ~410 adds.
      final stored = migrated(_fixtureBlob);
      final pages = fallback(_fixtureBlob);

      adoptRowIdentities(pages, stored);
      final wanted = pageItems(pages);

      final diff = diffConfigItems(stored: stored, wanted: wanted);
      expect(diff.added, isEmpty);
      expect(diff.changed, isEmpty);
      expect(diff.removed, isEmpty);
    });

    test('two byte-identical assets adopt in position order', () {
      // The fixture's home page carries two LEDs identical but for x, and a
      // real page carries rows of genuinely identical drives. Payload equality
      // cannot tell those apart, so position is the tiebreak — and getting it
      // wrong swaps two rows' history for nothing.
      final stored = migrated(_fixtureBlob);
      final pages = fallback(_fixtureBlob);
      adoptRowIdentities(pages, stored);

      final home = pages['/']!;
      final rows = [
        for (final item in stored)
          if (item.kind == ConfigKind.asset && item.parentId == home.id) item,
      ]..sort((a, b) => (a.sortIndex ?? 0).compareTo(b.sortIndex ?? 0));
      for (var i = 0; i < home.assets.length; i++) {
        expect(home.assets[i].id, rows[i].id,
            reason: 'asset $i must adopt the row at index $i');
      }
    });

    test('an asset the rows have never seen is left for pageItems to mint',
        () {
      final stored = migrated(_fixtureBlob);
      final pages = fallback(_fixtureBlob);
      final home = pages['/']!;
      final added = LEDConfig(key: 'CN99.New')
        ..coordinates = Coordinates(x: 0.9, y: 0.9)
        ..size = const RelativeSize(width: 0.03, height: 0.03);
      home.assets.add(added);

      adoptRowIdentities(pages, stored);

      expect(added.id, isNull,
          reason: 'nothing stored is this asset, so nothing may be copied '
              'onto it; `pageItems` mints a random id');
      // And the ones that were there still adopted.
      expect(home.assets.take(home.assets.length - 1).every((a) => a.id != null),
          isTrue);
    });

    test('a page whose id is already stored is left entirely alone', () {
      final stored = migrated(_fixtureBlob);
      final pages = fallback(_fixtureBlob);
      // The steady state: this page came off the rows, so it and its assets
      // carry ids. A new asset on it must NOT take a deleted sibling's row.
      final home = pages['/']!;
      home.id = 'aaaaaaaaaaaaaaaaaaaaaaaa';
      for (final asset in home.assets) {
        asset.id = null;
      }

      adoptRowIdentities(pages, stored);

      expect(home.assets.every((a) => a.id == null), isTrue,
          reason: 'adoption is the rollout-day repair for a page with no '
              'identity at all, not a general re-pairing pass');
    });

    test('nothing happens when the store holds no page rows', () {
      final pages = fallback(_fixtureBlob);
      adoptRowIdentities(pages, const <ConfigItem>[]);
      expect(pages.values.every((p) => p.id == null), isTrue);
      expect(pages.values.expand((p) => p.assets).every((a) => a.id == null),
          isTrue);
    });

    test('an id is never derived, only copied', () {
      // The collision the groundwork fixed: deriving at save gives two
      // editors' new assets the same id. Adoption must copy or do nothing.
      final stored = migrated(_fixtureBlob);
      final pages = fallback(_fixtureBlob);
      pages['/roe'] = AssetPage(
        menuItem: const MenuItem(label: 'Roe', path: '/roe', icon: Icons.egg),
        assets: [],
        mirroringDisabled: false,
      );

      adoptRowIdentities(pages, stored);

      expect(pages['/roe']!.id, isNull);
      expect(pages['/roe']!.id, isNot(derivedPageId('/roe')));
      final storedIds = {for (final item in stored) item.id};
      for (final page in pages.values) {
        if (page.id != null) expect(storedIds, contains(page.id));
        for (final asset in page.assets) {
          if (asset.id != null) expect(storedIds, contains(asset.id));
        }
      }
    });
  });

  group('a blob that is not one', () {
    test('a JSON array is rejected rather than read as an empty layout', () {
      expect(() => pageItemsFromBlob('[]'), throwsFormatException);
    });
  });
}

/// [layout] with every asset's `id` removed, at every depth.
///
/// The migration adds an id to assets that had none, which is a real change to
/// the stored JSON and the one difference the round-trip comparison must
/// tolerate. Recursive because a composite's subdevices are assets too.
Object? _withoutAssetIds(Object? layout) {
  if (layout is Map) {
    return {
      for (final entry in layout.entries)
        if (entry.key != 'id') entry.key: _withoutAssetIds(entry.value),
    };
  }
  if (layout is List) return layout.map(_withoutAssetIds).toList();
  return layout;
}
