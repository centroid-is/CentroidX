import 'package:flutter/material.dart';

import '../chat/ai_context_action.dart';
import '../chat/chat_overlay.dart' show ChatContextType;
import '../page_creator/assets/common.dart';
import '../page_creator/page.dart';
import 'asset_context_menu.dart' show extractAssetIdentifier;

/// Builds a structured context block from a page's data.
///
/// Includes the page name, path, asset count, mirroring config, and a summary
/// of each asset (type, key/label, position, size). Wrapped in markers so the
/// LLM knows not to re-fetch via list_assets or get_page.
String buildPageContextBlock(String pagePath, AssetPage page) {
  final buf = StringBuffer();
  buf.writeln(
      '[PAGE CONTEXT - already fetched, do NOT re-fetch with list_assets or get_page]');
  buf.writeln('Name: ${page.menuItem.label}');
  buf.writeln('Path: $pagePath');
  buf.writeln('Mirroring disabled: ${page.mirroringDisabled}');
  buf.writeln('Zoom and pan disabled: ${page.zoomPanDisabled}');
  buf.writeln('Assets (${page.assets.length}):');

  for (final asset in page.assets) {
    final identifier = extractAssetIdentifier(asset);
    final type = asset.displayName;
    final coords = asset.coordinates;
    final size = asset.size;
    buf.writeln(
        '  - $type: $identifier (pos: ${coords.x.toStringAsFixed(2)}, ${coords.y.toStringAsFixed(2)}; size: ${size.width.toStringAsFixed(2)} x ${size.height.toStringAsFixed(2)})');
  }

  buf.writeln('[END PAGE CONTEXT]');
  return buf.toString();
}

/// Sentinel value for the "Create New Page" menu item prefillText.
///
/// The page editor checks for this value to intercept the selection and open
/// the page creation dialog instead of opening the chat overlay.
const kCreateNewPageAction = '__CREATE_NEW_PAGE__';

/// Returns the context menu items for the page selector in the page editor.
///
/// Includes:
/// - **Create New Page** -- direct action to open the page creation dialog
///   (intercepted by the page editor; not an AI chat action)
/// - **Describe this page** -- prefills a prompt asking the LLM to describe
///   the page's purpose and assets
/// - **Improve layout** -- prefills a prompt asking for layout suggestions
/// - **Create similar page** -- prefills a prompt to create a new page based
///   on this one
///
/// AI items attach the page context block as hidden context, shown as a
/// small chip indicator in the chat input area.
List<AiMenuItem> buildPageSelectorMenuItems(
    String pagePath, AssetPage page) {
  final pageName = page.menuItem.label;
  final contextBlock = buildPageContextBlock(pagePath, page);
  final contextLabel = 'Page: $pageName';

  return [
    const AiMenuItem(
      label: 'Create Page with AI',
      prefillText: kCreateNewPageAction,
      icon: Icons.add_circle_outline,
    ),
    AiMenuItem(
      label: 'Describe this page',
      prefillText:
          'Describe the "$pageName" page -- what does it show and how is it organized?',
      icon: Icons.description,
      contextBlock: contextBlock,
      contextLabel: contextLabel,
      contextType: ChatContextType.page,
    ),
    AiMenuItem(
      label: 'Improve layout',
      prefillText:
          'Suggest layout improvements for the "$pageName" page to make it clearer and more usable.',
      icon: Icons.auto_fix_high,
      contextBlock: contextBlock,
      contextLabel: contextLabel,
      contextType: ChatContextType.page,
    ),
    AiMenuItem(
      label: 'Create similar page',
      prefillText:
          'Create a new page similar to "$pageName" but for a different section of the plant.\n\nUser input: ',
      icon: Icons.content_copy,
      contextBlock: contextBlock,
      contextLabel: contextLabel,
      contextType: ChatContextType.page,
    ),
  ];
}
