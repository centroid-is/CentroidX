import 'package:flutter_test/flutter_test.dart';

import 'package:tfc/page_creator/assets/registry.dart';
import 'package:tfc/page_creator/assets/web_view.dart' show WebViewAssetConfig;
import 'package:tfc_mcp_server/tfc_mcp_server.dart'
    show AssetTypeCatalog, kValidAssetTypes;

/// AssetTypeCatalog in the MCP package describes the asset types the
/// Flutter-side AssetRegistry can instantiate -- the package cannot depend
/// on the app layer, so the catalog cannot be derived from the registry.
/// This test is what keeps it honest: it fails whenever an asset is added
/// to (or removed from) AssetRegistry without a matching catalog entry in
/// packages/tfc_mcp_server/lib/src/services/asset_type_catalog.dart.
void main() {
  test('AssetTypeCatalog matches AssetRegistry.defaultFactories exactly', () {
    final registryNames =
        AssetRegistry.defaultFactories.keys.map((t) => t.toString()).toSet();
    final catalogNames =
        AssetTypeCatalog.all.map((t) => t.assetName).toSet();

    expect(AssetTypeCatalog.all.length, catalogNames.length,
        reason: 'AssetTypeCatalog contains duplicate assetName entries');

    expect(
      catalogNames.difference(registryNames),
      isEmpty,
      reason: 'AssetTypeCatalog describes types AssetRegistry cannot '
          'create -- remove them from asset_type_catalog.dart',
    );
    expect(
      registryNames.difference(catalogNames),
      isEmpty,
      reason: 'AssetRegistry has types missing from AssetTypeCatalog -- '
          'add entries to asset_type_catalog.dart so the MCP write tools '
          'and get_asset_types advertise them',
    );
  });

  test('the Web page catalog entry lists every field the config saves', () {
    // Fully populated, so fields omitted from the JSON while null (the theme
    // URL parameter trio) are present too.
    final json = WebViewAssetConfig(
      url: 'https://plant/x',
      themeParam: 'theme',
      themeDarkValue: 'dark',
      themeLightValue: 'light',
    ).toJson();
    const base = {
      'asset_name',
      'id',
      'coordinates',
      'size',
      'text',
      'textPos',
      'techDocId',
      'plcAssetKey',
    };
    final saved = json.keys.toSet().difference(base);
    final described = AssetTypeCatalog.all
        .singleWhere((t) => t.assetName == 'WebViewAssetConfig')
        .properties
        .map((p) => p.name)
        .toSet();
    expect(described, saved,
        reason: 'asset_type_catalog.dart must describe exactly the fields '
            'WebViewAssetConfig saves, so propose_asset can set them');
  });

  test('kValidAssetTypes is derived from the catalog', () {
    expect(
      kValidAssetTypes,
      AssetTypeCatalog.all.map((t) => t.assetName).toList(),
    );
  });
}
