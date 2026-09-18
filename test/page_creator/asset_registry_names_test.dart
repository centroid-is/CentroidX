@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/registry.dart';

/// The stored asset names are literals, and this arm is what keeps them honest.
///
/// `AssetRegistry` resolves a page row's `asset_name` through a
/// `Map<Type, String>` rather than through `Type.toString()`, because dart2js
/// minifies type names and a release web build therefore matched nothing: every
/// asset fell to the unrecognized path and every plant page drew empty.
///
/// The cost of that fix is a second place the names are written. On the VM
/// `Type.toString()` still *is* the class name, so this suite can hold the two
/// against each other — which turns the two failure modes back into test
/// failures:
///
///   * a new asset registered with no entry in the name table, which would
///     work on a station and render nothing in a browser;
///   * a Dart class renamed without the plant's rows being migrated, which
///     would orphan every row carrying the old name.
void main() {
  test('every registered factory has a stored name', () {
    final named = AssetRegistry.registeredNames;
    final missing = AssetRegistry.fromJsonTypesForTest
        .where((t) => !named.containsKey(t))
        .toList();

    expect(missing, isEmpty,
        reason: 'these types can be parsed out of a page but have no entry in '
            "AssetRegistry's name table, so `BaseAsset` would write a minified "
            'token into `asset_name` in a web build and no station could read '
            'the row back:\n${missing.map((t) => '  $t').join('\n')}');
  });

  test('every stored name is that type\'s class name on the VM', () {
    final wrong = <String>[];
    AssetRegistry.registeredNames.forEach((type, name) {
      if (type.toString() != name) {
        wrong.add('  $name  (the class is actually ${type.toString()})');
      }
    });

    expect(wrong, isEmpty,
        reason: 'a stored name no longer matches its class. If the class was '
            'renamed deliberately, the plant\'s existing rows still carry the '
            'old string — keep the literal, or migrate the rows. If the table '
            'entry was mistyped, fix the table.\n${wrong.join('\n')}');
  });

  test('no two types share a stored name', () {
    final byName = <String, List<Type>>{};
    AssetRegistry.registeredNames.forEach((type, name) {
      byName.putIfAbsent(name, () => []).add(type);
    });
    final clashes = byName.entries.where((e) => e.value.length > 1).toList();

    expect(clashes, isEmpty,
        reason: 'the reverse lookup is a map from name to type, so a duplicate '
            'name silently resolves to whichever was inserted last:\n'
            '${clashes.map((e) => '  ${e.key}: ${e.value}').join('\n')}');
  });

  test('the table is not empty — this suite cannot pass vacuously', () {
    // Each arm above is "no offenders", and an empty table reports exactly
    // that. Sixty types were registered when this was written; the floor is
    // well below it and only guards against the table disappearing.
    expect(AssetRegistry.registeredNames.length, greaterThan(40));
    expect(AssetRegistry.fromJsonTypesForTest.length, greaterThan(40));
  });

  test('a stored name resolves to a default asset carrying that same name', () {
    // The round trip the web build actually broke: build an asset from the
    // palette, and what it writes into the page must be what `parse` reads
    // back. `nameOf` is what `BaseAsset` uses for its own `assetName`.
    for (final entry in AssetRegistry.registeredNames.entries) {
      final asset = AssetRegistry.createDefaultAssetByName(entry.value);
      if (asset == null) continue; // palette entry behind a feature flag
      expect(AssetRegistry.nameOf(asset.runtimeType), entry.value,
          reason: 'a default ${entry.value} came back as a '
              '${asset.runtimeType}, whose stored name is '
              '${AssetRegistry.nameOf(asset.runtimeType)}');
    }
  });
}
