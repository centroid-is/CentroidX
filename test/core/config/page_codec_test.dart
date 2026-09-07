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
/// and the same assertions run over it. `tools/svn_apply_config.py
/// --backup-only` produces a file of the right shape.
library;

import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/config/page_codec.dart';
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
      // Late migrators only converge if the id-bearing blob is dual-written
      // back — which requires deployed editors to preserve ids they do not
      // know about. `BaseAsset.id` is `@JsonKey(includeIfNull: false)`, so it
      // round-trips when set and is absent when not. If that ever changes,
      // every migrated id is lost on the next save by an old station.
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
      expect(diff.changed.single.id, '/');
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
