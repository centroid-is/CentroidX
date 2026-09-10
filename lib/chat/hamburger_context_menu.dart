import 'package:flutter/material.dart';

import '../page_creator/assets/common.dart';
import '../page_creator/assets/registry.dart';
// Chat is not compiled for the browser; see `editor_ai.dart`.
import 'editor_ai.dart';
import 'chat_context_types.dart' show ChatContextType;

/// Builds a structured context block describing the current page state.
///
/// Includes:
/// - Page name
/// - Summary of existing assets (type + key/label for each)
/// - Available asset types from [AssetRegistry.defaultFactories]
///
/// Wrapped in `[PAGE CONTEXT ...]` markers so the LLM knows this data is
/// already fetched and should not be re-fetched.
String buildPageContextBlock({
  required String pageName,
  required List<Asset> assets,
}) {
  final buf = StringBuffer();
  buf.writeln(
    '[PAGE CONTEXT - already fetched, do NOT re-fetch with list_assets]',
  );
  buf.writeln('Page: $pageName');

  // Existing assets summary
  if (assets.isEmpty) {
    buf.writeln('Existing assets: none');
  } else {
    buf.writeln('Existing assets (${assets.length}):');
    for (final asset in assets) {
      final identifier = extractAssetIdentifier(asset);
      buf.writeln('  - ${asset.displayName}: $identifier');
    }
  }

  // Available asset types
  buf.writeln('Available asset types:');
  final typeNames = AssetRegistry.defaultFactories.entries.map((entry) {
    final preview = entry.value();
    return preview.displayName;
  }).toSet().toList()
    ..sort();
  for (final name in typeNames) {
    buf.writeln('  - $name');
  }

  buf.writeln('[END PAGE CONTEXT]');
  return buf.toString();
}

/// Returns AI context menu items for the hamburger FAB in the page editor.
///
/// Includes:
/// - **Create asset with AI** -- opens chat to help create/configure an asset
/// - **Design page layout** -- opens chat to suggest a layout arrangement
/// - **Add multiple assets** -- opens chat to add multiple related assets
///
/// All items attach a page context block with current page state and
/// available asset types.
List<AiMenuItem> buildHamburgerMenuItems({
  required String pageName,
  required List<Asset> assets,
}) {
  final contextBlock = buildPageContextBlock(
    pageName: pageName,
    assets: assets,
  );

  return [
    AiMenuItem(
      label: 'Create asset with AI',
      prefillText:
          'Create a new asset for page "$pageName" — suggest the best asset type and configure it\n\nUser input: ',
      icon: Icons.add_circle_outline,
      contextBlock: contextBlock,
      contextLabel: pageName,
      contextType: ChatContextType.page,
    ),
    AiMenuItem(
      label: 'Design page layout',
      prefillText:
          'Suggest a layout for page "$pageName" — recommend asset arrangement and positioning\n\nUser input: ',
      icon: Icons.dashboard_customize,
      contextBlock: contextBlock,
      contextLabel: pageName,
      contextType: ChatContextType.page,
    ),
    AiMenuItem(
      label: 'Add multiple assets',
      prefillText:
          'Help me add multiple related assets to page "$pageName" (e.g., a pump with speed, pressure, and status indicators)\n\nUser input: ',
      icon: Icons.library_add,
      contextBlock: contextBlock,
      contextLabel: pageName,
      contextType: ChatContextType.page,
    ),
  ];
}
