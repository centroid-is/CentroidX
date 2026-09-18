@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/registry.dart';

/// The stored names of the asset types, pinned.
///
/// A page row carries each asset as `asset_name: "BpmConfig"` — the Dart class
/// name, as every build before the browser wrote it. The registry now resolves
/// that string through a table of literals keyed by `Type`, because dart2js
/// minifies `Type.toString()` and a release web build matched nothing (every
/// plant page drew empty, 2026-09-16). Three things have to stay true, and each
/// arm holds one:
///
///  * every registered type has a name, and on the VM — where a type still
///    spells itself — that name IS the class name, so a rename fails here
///    instead of orphaning every row that carries the old spelling;
///  * an asset a default factory builds calls itself by the same name, so a
///    page written by a browser reads back on a station;
///  * the two directions agree: what `toJson` writes, `parse` finds.
void main() {
  group('the asset name table', () {
    test('every registered type has a name, and it is the class name', () {
      final names = AssetRegistry.registeredNames;
      final registered = {
        ...AssetRegistry.defaultFactories.keys,
        ...AssetRegistry.fromJsonTypesForTest,
      };
      expect(registered, isNotEmpty);
      for (final type in registered) {
        expect(names[type], isNotNull,
            reason: '$type is registered but has no stored name; in a '
                'browser its rows would be unrecognized');
        expect(names[type], type.toString(),
            reason: 'the stored name of $type is "${names[type]}", not its '
                'class name. If the class was renamed, the plant\'s rows '
                'still say "${names[type]}": keep the literal, or migrate '
                'the rows — never let the two drift silently');
      }
    });

    test('names are unique, so a name resolves to one type', () {
      final names = AssetRegistry.registeredNames.values.toList();
      expect(names.toSet().length, names.length);
    });

    test('a default-built asset calls itself by its stored name', () {
      for (final entry in AssetRegistry.defaultFactories.entries) {
        final Asset asset;
        try {
          asset = entry.value();
        } catch (_) {
          continue; // a preview that needs a platform is not this arm's business
        }
        expect(asset.assetName, AssetRegistry.nameOf(entry.key),
            reason: '${entry.key}.preview() would write a different '
                'asset_name than the registry reads back');
        expect(asset.displayName, isNot(contains('minified')),
            reason: 'the palette label derives from the stored name');
      }
    });

    test('what a default asset writes, parse reads back as the same type', () {
      for (final entry in AssetRegistry.defaultFactories.entries) {
        final Asset asset;
        try {
          asset = entry.value();
        } catch (_) {
          continue;
        }
        final parsed = AssetRegistry.parse({
          'assets': [asset.toJson()]
        });
        expect(parsed, hasLength(1),
            reason: '${entry.key} did not round-trip through asset_name');
        expect(parsed.single.runtimeType, entry.key);
      }
    });

    test('an unknown name is not found, by name, and creates no default', () {
      expect(AssetRegistry.createDefaultAssetByName('NoSuchConfig'), isNull);
      expect(
          AssetRegistry.parse({
            'assets': [
              {'asset_name': 'NoSuchConfig'}
            ]
          }),
          isEmpty);
    });

    test('a late registration without a name falls back to the class name',
        () {
      AssetRegistry.registerDefaultFactory<_LateConfig>(_LateConfig.new);
      expect(AssetRegistry.nameOf(_LateConfig), '_LateConfig');
      expect(AssetRegistry.createDefaultAssetByName('_LateConfig'),
          isA<_LateConfig>());
      AssetRegistry.registerDefaultFactory<_LateConfig>(_LateConfig.new,
          name: 'LateByName');
      expect(AssetRegistry.nameOf(_LateConfig), 'LateByName');
      expect(AssetRegistry.createDefaultAssetByName('LateByName'),
          isA<_LateConfig>());
    });
  });
}

/// A registered-late asset, as an integrator's `registerDefaultFactory` call
/// in `main.dart` would add.
class _LateConfig extends BaseAsset {
  _LateConfig();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  @override
  Widget configure(BuildContext context) => const SizedBox.shrink();

  @override
  Map<String, dynamic> toJson() => {constAssetName: assetName};
}
