import 'package:flutter/material.dart';

import '../page_creator/assets/common.dart';
// Chat is not compiled for the browser; see `editor_ai.dart`.
import 'editor_ai.dart';
import 'chat_context_types.dart' show ChatContextType;

/// Builds a structured context block for a palette asset type.
///
/// Unlike [buildAssetContextBlock] in `asset_context_menu.dart` which
/// describes a *placed* asset with key mappings, this describes an asset
/// *type* from the palette (no key, no instance data).
///
/// Optionally includes the current page name and a summary of existing
/// assets on the page, so the LLM can suggest good placement and
/// configuration.
String buildPaletteTypeContextBlock({
  required Asset asset,
  String? pageName,
  String? existingAssetSummary,
}) {
  final buf = StringBuffer();
  buf.writeln('[ASSET TYPE CONTEXT]');
  buf.writeln('Type: ${asset.displayName}');
  buf.writeln('Category: ${asset.category}');
  if (pageName != null && pageName.isNotEmpty) {
    buf.writeln('Current page: $pageName');
  }
  if (existingAssetSummary != null && existingAssetSummary.isNotEmpty) {
    buf.writeln('Existing assets on page: $existingAssetSummary');
  }
  buf.writeln('[END ASSET TYPE CONTEXT]');
  return buf.toString();
}

/// Builds a short, user-friendly prompt for explaining an asset type.
String buildExplainTypePrompt(String displayName) {
  return 'Explain the "$displayName" asset type';
}

/// Builds a short, user-friendly prompt for creating an asset with AI help.
String buildCreateWithAiPrompt(String displayName, {String? pageName}) {
  if (pageName != null && pageName.isNotEmpty) {
    return 'Help me add a "$displayName" to page "$pageName"\n\nUser input: ';
  }
  return 'Help me add a "$displayName" to my page\n\nUser input: ';
}

/// Builds the LLM instructions for explaining a palette asset type.
String _buildExplainTypeInstructions() {
  return '''Please describe:
- What this asset type is and what it displays
- When to use it and typical use cases
- What configuration it needs (key mappings, settings, etc.)
- Any tips or best practices for using this asset type effectively''';
}

/// Builds the LLM instructions for creating an asset with AI help.
String _buildCreateWithAiInstructions() {
  return '''Please help me configure and place this asset type:
- Suggest appropriate key mappings based on available tags (use list_tags)
- Recommend display settings and configuration values
- Suggest good placement considering the existing assets on the page
- Provide the configuration as a proposal I can accept''';
}

/// Returns the standard AI context menu items for a palette item in the
/// page editor sidebar.
///
/// Includes:
/// - **Explain this type** -- opens chat asking the LLM to explain what this
///   asset type is, when to use it, what it displays, what configuration it
///   needs.
/// - **Create this with AI** -- opens chat asking the LLM to help configure
///   and place this specific asset type on the current page.
///
/// Both items attach the asset type context block as hidden context, shown
/// as a small chip indicator in the chat input area.
List<AiMenuItem> buildPaletteItemMenuItems({
  required Asset asset,
  String? pageName,
  String? existingAssetSummary,
}) {
  final displayName = asset.displayName;

  final explainContextBlock = buildPaletteTypeContextBlock(
    asset: asset,
  );
  final explainInstructions = _buildExplainTypeInstructions();

  final createContextBlock = buildPaletteTypeContextBlock(
    asset: asset,
    pageName: pageName,
    existingAssetSummary: existingAssetSummary,
  );
  final createInstructions = _buildCreateWithAiInstructions();

  return [
    AiMenuItem(
      label: 'Explain this type',
      prefillText: buildExplainTypePrompt(displayName),
      icon: Icons.help_outline,
      contextBlock: '$explainContextBlock\n$explainInstructions',
      contextLabel: displayName,
      contextType: ChatContextType.asset,
    ),
    AiMenuItem(
      label: 'Create this with AI',
      prefillText: buildCreateWithAiPrompt(displayName, pageName: pageName),
      icon: Icons.auto_awesome,
      contextBlock: '$createContextBlock\n$createInstructions',
      contextLabel: displayName,
      contextType: ChatContextType.asset,
    ),
  ];
}

/// Summarizes a list of assets by counting occurrences of each display name.
///
/// Returns a comma-separated string like "2 LEDs, 1 Number, 3 Buttons".
/// Returns an empty string for an empty list.
String summarizeExistingAssets(List<Asset> assets) {
  if (assets.isEmpty) return '';

  final counts = <String, int>{};
  for (final asset in assets) {
    final name = asset.displayName;
    counts[name] = (counts[name] ?? 0) + 1;
  }

  final parts = <String>[];
  for (final entry in counts.entries) {
    final count = entry.value;
    final name = entry.key;
    if (count == 1) {
      parts.add('$count $name');
    } else {
      parts.add('$count ${name}s');
    }
  }
  return parts.join(', ');
}
