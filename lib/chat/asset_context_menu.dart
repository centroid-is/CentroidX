import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart' show Expression;
import 'package:tfc_mcp_server/tfc_mcp_server_data.dart'
    show DrawingIndex, DrawingSearchResult, PlcCodeBlock, PlcCodeIndex, PlcContext, TechDocIndex, TechDocSection;

import '../page_creator/assets/common.dart';
import '../providers/drawing.dart' show drawingIndexProvider;
import '../providers/alarm.dart' show alarmManProvider;
import '../providers/plc.dart' show plcCodeIndexProvider, plcContextServiceProvider;
import '../providers/state_man.dart' show stateManProvider;
import '../providers/tech_doc.dart' show techDocIndexProvider;
import 'ai_context_action.dart';
import 'chat_overlay.dart' show ChatContext, ChatContextType, chatContextProvider;

/// Resolves `$variable` patterns in a list of HMI keys using substitution values.
///
/// Uses the same `$varName` pattern as [StateMan.resolveKey]. Keys without
/// `$` are passed through unchanged. When a substitution value is not found,
/// the literal key is kept (graceful degradation).
List<String> resolveVariableKeys(List<String> keys, Map<String, String> substitutions) {
  if (keys.isEmpty || substitutions.isEmpty) return List.of(keys);
  return keys.map((key) {
    if (!key.contains(r'$')) return key;
    String resolved = key;
    for (final entry in substitutions.entries) {
      final pattern = '\$${entry.key}';
      if (resolved.contains(pattern)) {
        resolved = resolved.replaceAll(pattern, entry.value);
      }
    }
    return resolved;
  }).toList();
}

/// Extracts PLC tag references embedded in boolean expression formulas.
///
/// Walks the [json] map looking for `expression.value.formula` patterns
/// (e.g., in `conditional_states`, top-level `expression` fields, or alarm
/// rule expressions). Uses [Expression.extractVariables] for reliable parsing.
///
/// Returns a deduplicated list of tag names found in all formulas.
/// Returns an empty list when no formulas are found or all are empty.
List<String> extractExpressionTags(Map<String, dynamic> json) {
  final tags = <String>{};
  _collectFormulas(json, tags);
  return tags.toList();
}

/// Recursively walks a JSON structure collecting formula strings.
///
/// Handles both fully-serialized maps (`{'formula': '...'}`) and live
/// [Expression] objects that appear when `ExpressionConfig.toJson()` is
/// generated without `explicitToJson: true` (the `value` field stores the
/// raw [Expression] instance instead of calling `.toJson()` on it).
void _collectFormulas(dynamic value, Set<String> tags) {
  if (value is Expression) {
    // Live Expression object (not serialized to Map) -- extract directly.
    if (value.formula.isNotEmpty) {
      try {
        tags.addAll(value.extractVariables());
      } catch (_) {
        // Malformed formula -- skip.
      }
    }
  } else if (value is Map) {
    // Direct formula field: { "formula": "pump3.running == TRUE" }
    final formula = value['formula'];
    if (formula is String && formula.isNotEmpty) {
      try {
        final vars = Expression(formula: formula).extractVariables();
        tags.addAll(vars);
      } catch (_) {
        // Malformed formula -- skip.
      }
    }
    // Recurse into nested maps and values (which may be Expression objects).
    for (final v in value.values) {
      _collectFormulas(v, tags);
    }
  } else if (value is List) {
    for (final item in value) {
      _collectFormulas(item, tags);
    }
  }
}

/// Extracts a human-readable identifier from an [Asset].
///
/// Priority: `toJson()['key']` > `asset.text` > `asset.displayName`.
/// Key-bearing assets (LED, Button, Number) have a `key` field in their JSON;
/// keyless assets (Arrow, DrawnBox, TextAsset) fall back to text label or displayName.
String extractAssetIdentifier(Asset asset) {
  final json = asset.toJson();
  final key = json['key'] as String?;
  if (key != null && key.isNotEmpty) return key;
  final text = asset.text;
  if (text != null && text.isNotEmpty) return text;
  return asset.displayName;
}

/// Builds a structured context block from the asset's JSON data.
///
/// Extracts key configuration fields (key, type, text label, units, scale,
/// writable flag, graph config) and formats them into a clearly marked block
/// that tells the LLM the data is already fetched and should not be re-fetched.
String buildAssetContextBlock(Asset asset) {
  final json = asset.toJson();
  final key = json['key'] as String?;
  final assetType = asset.displayName;
  final assetName = json[constAssetName] as String? ?? asset.assetName;
  final text = asset.text;

  final buf = StringBuffer();
  buf.writeln('[ASSET CONTEXT - already fetched, do NOT re-fetch with get_asset_detail or list_assets]');
  buf.writeln('Type: $assetType ($assetName)');
  if (key != null && key.isNotEmpty) {
    buf.writeln('Key: $key');
  }
  if (text != null && text.isNotEmpty) {
    buf.writeln('Label: $text');
  }

  // Include position/size for spatial context.
  final coords = json['coordinates'];
  if (coords is Map) {
    final x = coords['x'];
    final y = coords['y'];
    if (x != null && y != null) {
      final angle = coords['angle'];
      buf.writeln('Position: x=$x, y=$y${angle != null ? ', angle=$angle' : ''}');
    }
  }
  final size = json['size'];
  if (size is Map) {
    final w = size['width'];
    final h = size['height'];
    if (w != null && h != null) {
      buf.writeln('Size: ${w}x$h');
    }
  }

  // Include visual properties (icon, color) for display-oriented assets.
  final iconData = json['iconData'];
  if (iconData != null) {
    buf.writeln('Icon: $iconData');
  }
  final color = json['color'];
  if (color is Map && color.isNotEmpty) {
    final colorValue = color['value'];
    if (colorValue != null) {
      buf.writeln('Color: $colorValue');
    }
  }

  // Include relevant config fields from the JSON
  final units = json['units'] as String?;
  if (units != null && units.isNotEmpty) {
    buf.writeln('Units: $units');
  }
  final scale = json['scale'];
  if (scale != null) {
    buf.writeln('Scale: $scale');
  }
  final writable = json['writable'] as bool?;
  if (writable == true) {
    buf.writeln('Writable: true');
  }
  final decimalPlaces = json['decimalPlaces'] as int?;
  if (decimalPlaces != null) {
    buf.writeln('Decimal places: $decimalPlaces');
  }

  // Include graph config if present
  final graphConfig = json['graph_config'];
  if (graphConfig != null) {
    buf.writeln('Graph config: ${jsonEncode(graphConfig)}');
  }

  // Include expression if present (e.g., LED boolean expression)
  final expression = json['expression'];
  if (expression != null) {
    buf.writeln('Expression: ${jsonEncode(expression)}');
  }

  // Include any sub-keys (e.g., LED off_key, on_key)
  for (final subKey in ['off_key', 'on_key', 'feedback_key', 'command_key']) {
    final v = json[subKey] as String?;
    if (v != null && v.isNotEmpty) {
      buf.writeln('${_humanizeFieldName(subKey)}: $v');
    }
  }

  // Include conditional states (e.g., IconConfig boolean-expression-driven states).
  final conditionalStates = json['conditional_states'];
  if (conditionalStates is List && conditionalStates.isNotEmpty) {
    buf.writeln('Conditional states (${conditionalStates.length}):');
    for (var i = 0; i < conditionalStates.length; i++) {
      final state = conditionalStates[i];
      if (state is Map) {
        final expr = state['expression'];
        // ExpressionConfig.toJson() may store the Expression object directly
        // (when generated without explicitToJson: true) or as a nested Map.
        String? formula;
        if (expr is Map) {
          final exprValue = expr['value'];
          if (exprValue is Expression) {
            // Live Expression object -- read formula directly.
            formula = exprValue.formula;
          } else if (exprValue is Map) {
            // Fully serialized: {'value': {'formula': '...'}}
            formula = exprValue['formula']?.toString();
          }
        }
        if (formula != null && formula.isNotEmpty) {
          buf.writeln('  State ${i + 1}: expression=$formula');
        } else {
          buf.writeln('  State ${i + 1}: (no expression)');
        }
      }
    }
  }

  buf.writeln('[END ASSET CONTEXT]');
  return buf.toString();
}

/// Converts snake_case field names to Title Case for display.
String _humanizeFieldName(String name) {
  return name.split('_').map((w) => w[0].toUpperCase() + w.substring(1)).join(' ');
}

/// Builds a structured context block from an [AlarmConfig].
///
/// Includes UID, key, title, description, and all rules with their level,
/// expression formula, and acknowledge-required flag. Wrapped in markers so
/// the LLM knows not to re-fetch via get_alarm_detail or list_alarm_definitions.
String buildAlarmContextBlock(AlarmConfig alarm) {
  final buf = StringBuffer();
  buf.writeln('[ALARM CONTEXT - already fetched, do NOT re-fetch with get_alarm_detail or list_alarm_definitions]');
  buf.writeln('UID: ${alarm.uid}');
  if (alarm.key != null && alarm.key!.isNotEmpty) {
    buf.writeln('Key: ${alarm.key}');
  }
  buf.writeln('Title: ${alarm.title}');
  buf.writeln('Description: ${alarm.description}');
  buf.writeln('Rules (${alarm.rules.length}):');
  for (var i = 0; i < alarm.rules.length; i++) {
    final rule = alarm.rules[i];
    buf.writeln('  Rule ${i + 1}:');
    buf.writeln('    Level: ${rule.level.name}');
    buf.writeln('    Expression: ${rule.expression.value.formula}');
    buf.writeln('    Acknowledge required: ${rule.acknowledgeRequired}');
    if (rule.onDelay > Duration.zero) {
      buf.writeln(
          '    Active after: ${rule.onDelay.inMilliseconds / 1000} s held');
    }
  }
  buf.writeln('[END ALARM CONTEXT]');
  return buf.toString();
}

/// Filters alarm configs to those whose key matches any of [assetKeys].
///
/// Matching uses prefix logic: alarm key `pump3` matches asset key
/// `pump3.speed`, and asset key `pump3.speed` matches alarm key
/// `pump3.speed.high`. Configs without a `key` field are skipped.
List<Map<String, dynamic>> filterAlarmConfigsByKeys(
  List<Map<String, dynamic>> allConfigs,
  List<String> assetKeys,
) {
  if (allConfigs.isEmpty || assetKeys.isEmpty) return [];
  return allConfigs.where((cfg) {
    final alarmKey = cfg['key'] as String?;
    if (alarmKey == null || alarmKey.isEmpty) return false;
    return assetKeys.any((ak) =>
        ak == alarmKey ||
        ak.startsWith('$alarmKey.') ||
        alarmKey.startsWith('$ak.'));
  }).toList();
}

/// Builds a structured `[ALARM CONTEXT]` prompt section from alarm configs
/// and optional recent history.
///
/// Returns an empty string when [alarmConfigs] is empty (graceful degradation).
/// History entries are capped at 20 to keep the prompt manageable.
String buildAlarmDefinitionsSection(
  List<Map<String, dynamic>> alarmConfigs,
  List<Map<String, dynamic>> alarmHistory,
) {
  if (alarmConfigs.isEmpty) return '';
  final buf = StringBuffer();
  buf.writeln('[ALARM CONTEXT - already fetched, do NOT call query_alarm_history or list_alarm_definitions]');
  buf.writeln('Defined alarms for this asset:');

  // Build a set of alarm UIDs for quick history lookup.
  final alarmUids = alarmConfigs.map((c) => c['uid'] as String?).whereType<String>().toSet();

  for (final cfg in alarmConfigs) {
    final uid = cfg['uid'] as String? ?? '';
    final title = cfg['title'] as String? ?? 'Untitled';
    final key = cfg['key'] as String? ?? '';
    final rules = cfg['rules'] as List<dynamic>? ?? [];

    // Build expression summary from rules.
    final exprParts = <String>[];
    for (final rule in rules) {
      if (rule is Map) {
        final expr = rule['expression'] as String?;
        final level = rule['level'] as String?;
        if (expr != null) {
          exprParts.add(level != null ? '$expr [$level]' : expr);
        }
      }
    }
    final exprStr = exprParts.isNotEmpty ? ' (${exprParts.join("; ")})' : '';

    // Check for recent history for this alarm.
    final ownHistory = alarmHistory.where((h) => h['alarmUid'] == uid).toList();
    final lastTrigger = ownHistory.isNotEmpty ? ownHistory.first : null;
    final statusStr = lastTrigger != null
        ? (lastTrigger['active'] == true ? ', currently ACTIVE' : ', currently INACTIVE')
        : ' \u2014 no recent triggers';

    buf.writeln('  - "$title"$exprStr$statusStr');
    if (key.isNotEmpty) buf.writeln('    Key: $key');
  }

  // Recent alarm history section (capped at 20 entries).
  final relevantHistory = alarmHistory
      .where((h) => alarmUids.contains(h['alarmUid']))
      .take(20)
      .toList();
  if (relevantHistory.isNotEmpty) {
    buf.writeln('');
    buf.writeln('Recent alarm history (24h):');
    for (final h in relevantHistory) {
      final createdAt = h['createdAt'] as String? ?? '';
      final title = h['alarmTitle'] as String? ?? '';
      final active = h['active'] as bool? ?? false;
      final expression = h['expression'] as String?;
      // Extract time portion for compact display.
      String timeStr;
      try {
        final dt = DateTime.parse(createdAt);
        timeStr = '${dt.hour.toString().padLeft(2, '0')}:'
            '${dt.minute.toString().padLeft(2, '0')}:'
            '${dt.second.toString().padLeft(2, '0')}';
      } catch (_) {
        timeStr = createdAt;
      }
      final action = active ? 'ACTIVATED' : 'DEACTIVATED';
      final exprSuffix = expression != null ? ' ($expression)' : '';
      buf.writeln('  $timeStr \u2014 $title $action$exprSuffix');
    }
  }

  buf.writeln('[END ALARM CONTEXT]');
  return buf.toString();
}

/// Fetches PLC code blocks relevant to the given asset key.
///
/// Uses mode `'key'` to correlate HMI key mappings (OPC UA paths) to PLC
/// variable declarations, then fetches full block content for each unique
/// block found. Returns an empty list when [plcCodeIndex] is null, the key
/// is empty, or an error occurs.
Future<List<PlcCodeBlock>> _fetchPlcCodeForAsset(
  String? assetKey,
  PlcCodeIndex? plcCodeIndex,
) async {
  if (assetKey == null || assetKey.isEmpty || plcCodeIndex == null) return [];
  try {
    final results = await plcCodeIndex.search(assetKey, mode: 'key', limit: 10);
    if (results.isEmpty) return [];
    // Deduplicate by blockId and fetch full blocks.
    final blockIds = results.map((r) => r.blockId).toSet();
    final blocks = <PlcCodeBlock>[];
    for (final id in blockIds) {
      final block = await plcCodeIndex.getBlock(id);
      if (block != null) blocks.add(block);
    }
    return blocks;
  } catch (_) {
    return [];
  }
}

/// Formats a list of [PlcCodeBlock]s into a marked context block for the LLM.
///
/// Returns an empty string when [blocks] is empty.
String _buildPlcCodeSection(List<PlcCodeBlock> blocks) {
  if (blocks.isEmpty) return '';
  final buf = StringBuffer();
  buf.writeln('[PLC CODE - already fetched, do NOT call search_plc_code]');
  for (final block in blocks) {
    buf.writeln('--- ${block.blockType}: ${block.blockName} (asset: ${block.assetKey}) ---');
    // Cap source at ~300 lines to avoid oversized prompts.
    final lines = block.fullSource.split('\n');
    final capped = lines.length > 300
        ? [...lines.take(300), '... (truncated, ${lines.length - 300} more lines)']
        : lines;
    for (final line in capped) {
      buf.writeln(line);
    }
    buf.writeln('');
  }
  buf.writeln('[END PLC CODE]');
  return buf.toString();
}

/// Formats a pre-computed [PlcContext] into LLM-ready text.
///
/// Returns an empty string when [context] has no resolved or unresolved keys.
/// The [plcContextFormatter] parameter allows injecting the formatting
/// function (defaults to creating a temporary [PlcContextService] instance
/// whose [formatForLlm] method only reads the data, not the backing services).
String buildPlcContextSection(PlcContext context, {String Function(PlcContext)? plcContextFormatter}) {
  if (context.resolvedKeys.isEmpty && context.unresolvedKeys.isEmpty) return '';
  if (plcContextFormatter != null) return plcContextFormatter(context);
  return _defaultFormatPlcContext(context);
}

/// Default formatter that mirrors [PlcContextService.formatForLlm] output.
///
/// Produces a compact one-line-per-edge call graph format.
String _defaultFormatPlcContext(PlcContext context) {
  final buffer = StringBuffer();

  if (context.resolvedKeys.isNotEmpty) {
    final byServer = <String, List<dynamic>>{};
    for (final key in context.resolvedKeys) {
      byServer.putIfAbsent(key.serverAlias, () => []).add(key);
    }
    for (final entry in byServer.entries) {
      buffer.writeln('[PLC CONTEXT - ${entry.key}]');
      buffer.writeln();
      for (final key in entry.value) {
        final typeStr = key.variableType != null ? ' (${key.variableType})' : '';
        final bitStr = _formatBitInfo(key.bitMask, key.bitShift);
        final declBlockStr = key.declaringBlock != null
            ? ' declared @ ${key.declaringBlock}'
            : '';
        final declLineStr = key.declarationLine != null
            ? '  |  ${key.declarationLine}'
            : '';
        buffer.writeln('${key.hmiKey} \u2192 ${key.plcVariablePath}$typeStr$bitStr$declBlockStr$declLineStr');

        if (key.fbInstance != null) {
          final fb = key.fbInstance!;
          final memberStr = fb.memberName != null ? '.${fb.memberName}' : '';
          final sectionStr = fb.memberSection != null ? ' (${fb.memberSection})' : '';
          buffer.writeln('  FB: ${fb.instanceName} is ${fb.fbTypeName}$memberStr$sectionStr');
        }

        for (final w in key.writers) {
          final lineStr = w.lineNumber != null ? ':${w.lineNumber}' : '';
          final srcStr = w.sourceLine != null ? '  |  ${w.sourceLine}' : '';
          buffer.writeln('  \u2190 ${w.blockName}$lineStr writes$srcStr');
        }

        for (final r in key.readers) {
          final lineStr = r.lineNumber != null ? ':${r.lineNumber}' : '';
          final srcStr = r.sourceLine != null ? '  |  ${r.sourceLine}' : '';
          buffer.writeln('  \u2190 ${r.blockName}$lineStr reads$srcStr');
        }

        buffer.writeln();
      }
      buffer.writeln('Use get_plc_code_block(block_name) to fetch full source for any block listed above.');
      buffer.writeln();
    }
  }

  if (context.unresolvedKeys.isNotEmpty) {
    buffer.writeln('[NON-PLC KEYS]');
    for (final key in context.unresolvedKeys) {
      final protocolStr = key.protocol != null ? _protocolDisplay(key.protocol!) : 'Unknown protocol';
      final reasonStr = key.reason != null ? ' (${key.reason})' : '';
      buffer.writeln('  ${key.hmiKey} \u2192 $protocolStr$reasonStr');
    }
  }

  return buffer.toString().trimRight();
}

/// Format bit mask/shift info for LLM display.
///
/// Returns empty string when [bitMask] is null.
/// Single-bit mask: `[bit N, mask 0xHH]`
/// Multi-bit mask: `[bits N-M, mask 0xHH]`
String _formatBitInfo(int? bitMask, int? bitShift) {
  if (bitMask == null) return '';
  final shift = bitShift ?? 0;
  final hexMask = '0x${bitMask.toRadixString(16).padLeft(2, '0')}';
  final isSingleBit = bitMask != 0 && (bitMask & (bitMask - 1)) == 0;
  if (isSingleBit) {
    return ' [bit $shift, mask $hexMask]';
  }
  final highBit = bitMask.bitLength - 1;
  return ' [bits $shift-$highBit, mask $hexMask]';
}

String _protocolDisplay(String protocol) {
  switch (protocol) {
    case 'opcua': return 'OPC-UA';
    case 'modbus': return 'Modbus';
    case 'm2400': return 'M2400';
    default: return protocol;
  }
}

/// Formats a map of live tag values into a marked context block for the LLM.
///
/// Returns an empty string when [liveValues] is null or empty.
/// Each entry is formatted as `key = value` on its own line.
String buildLiveValuesSection(Map<String, String>? liveValues) {
  if (liveValues == null || liveValues.isEmpty) return '';
  final buf = StringBuffer();
  buf.writeln('[LIVE VALUES - already fetched, do NOT re-fetch]');
  for (final entry in liveValues.entries) {
    buf.writeln('  ${entry.key} = ${entry.value}');
  }
  buf.writeln('[END LIVE VALUES]');
  return buf.toString();
}

/// Fetches drawing search results for all [keys] from [drawingIndex].
///
/// Searches each key individually and returns deduplicated results.
/// Returns an empty list when [drawingIndex] is null, [keys] is empty,
/// or an error occurs.
Future<List<DrawingSearchResult>> fetchDrawingsForAsset(
  List<String> keys,
  DrawingIndex? drawingIndex,
) async {
  if (drawingIndex == null || keys.isEmpty) return [];
  try {
    final allResults = <DrawingSearchResult>[];
    for (final key in keys) {
      final results = await drawingIndex.search(key);
      allResults.addAll(results);
    }
    return allResults;
  } catch (_) {
    return [];
  }
}

/// Formats a list of [DrawingSearchResult]s into a marked context block.
///
/// Deduplicates by drawing name + page number, merging component names
/// for the same page. Caps at 10 entries to keep prompts manageable.
/// Returns an empty string when [results] is empty.
String buildDrawingContextSection(List<DrawingSearchResult> results) {
  if (results.isEmpty) return '';

  // Deduplicate by (drawingName, pageNumber), merging componentNames.
  final deduped = <String, _DrawingEntry>{};
  for (final r in results) {
    final key = '${r.drawingName}|${r.pageNumber}';
    if (deduped.containsKey(key)) {
      deduped[key]!.componentNames.add(r.componentName);
    } else {
      deduped[key] = _DrawingEntry(
        drawingName: r.drawingName,
        pageNumber: r.pageNumber,
        componentNames: {r.componentName},
      );
    }
  }

  final entries = deduped.values.take(10).toList();
  final buf = StringBuffer();
  buf.writeln('[ELECTRICAL DRAWINGS - already fetched, do NOT call search_drawings]');
  buf.writeln('Relevant drawings for this asset:');
  for (final entry in entries) {
    final components = entry.componentNames.join(', ');
    buf.writeln('  - "${entry.drawingName}" page ${entry.pageNumber} — $components');
  }
  buf.writeln('');
  buf.writeln('Use get_drawing_page to view any drawing in detail.');
  buf.writeln('[END ELECTRICAL DRAWINGS]');
  return buf.toString();
}

/// Internal helper for deduplicating drawing search results.
class _DrawingEntry {
  _DrawingEntry({
    required this.drawingName,
    required this.pageNumber,
    required this.componentNames,
  });

  final String drawingName;
  final int pageNumber;
  final Set<String> componentNames;
}

/// Builds a structured diagnostic prompt for the LLM to investigate an asset.
///
/// Includes the full asset context block so the LLM does not need to call
/// get_asset_detail or list_assets. The LLM should still fetch live tag
/// values, alarm history, drawings, and PLC code as those are runtime data.
///
/// For assets with no PLC tag mappings (e.g., Icon, Arrow, DrawnBox, TextAsset),
/// produces a display-only summary instead of asking the LLM to call tools
/// that will return nothing.
///
/// This is the synchronous version used as a fallback when no tech doc is
/// linked or the tech doc index is unavailable.
String buildDebugAssetMessage(Asset asset) {
  final identifier = extractAssetIdentifier(asset);
  final context = buildAssetContextBlock(asset);
  final hasDirectKeys = (asset is BaseAsset) && asset.allKeys.isNotEmpty;
  final exprTags = extractExpressionTags(asset.toJson());
  final hasAnyTags = hasDirectKeys || exprTags.isNotEmpty;

  if (!hasAnyTags) {
    return '''Debug asset: $identifier

$context
This is a display-only asset with no PLC tag mappings and no expression references. There are no live values, alarms, PLC code, or electrical drawings directly associated with it.

Summarize what this asset does based on its configuration above.''';
  }

  if (!hasDirectKeys && exprTags.isNotEmpty) {
    // Asset has no key fields but references tags in expressions.
    return '''Debug asset: $identifier

$context
This asset has no direct PLC tag mappings, but its conditional expressions reference these tags: ${exprTags.join(', ')}

Please investigate these tags:
- Live tag values (use get_tag_value for each tag listed above)
- Related PLC code blocks (use search_plc_code)
- Available electrical drawings (use search_drawings)
Then provide a diagnostic summary of this asset and its conditional behavior.''';
  }

  return '''Debug asset: $identifier

$context
Please investigate this asset. The configuration above is already provided — do NOT re-fetch it with get_asset_detail or list_assets.
You need to gather ONLY the following (nothing else):
- Live tag values (use get_tag_value for the key above)
- Recent alarm history (use query_alarm_history)
- Available electrical drawings (use search_drawings)
- Related PLC code blocks (use search_plc_code)
- Technical documentation (use search_tech_docs, then get_tech_doc_section)
Then provide a diagnostic summary of the current state of this asset.''';
}

/// Builds a diagnostic prompt that includes linked technical documentation
/// and relevant PLC code.
///
/// When the asset has a non-null [BaseAsset.techDocId], fetches the document
/// name and all sections from [techDocIndex], then embeds them in a
/// `[TECHNICAL REFERENCE]` block. When PLC code is found for the asset key,
/// embeds it in a `[PLC CODE]` block.
///
/// Falls back to [buildDebugAssetMessage] when:
/// - The asset is not a [BaseAsset] or has no [techDocId]
/// - The [techDocIndex] is null (no database connection)
/// - The tech doc has no sections
/// (PLC code is still included even when tech docs are absent.)
Future<String> buildDebugAssetMessageWithTechDoc(
  Asset asset,
  TechDocIndex? techDocIndex, {
  PlcCodeIndex? plcCodeIndex,
  PlcContext? plcContext,
  Map<String, String>? liveValues,
  DrawingIndex? drawingIndex,
  List<Map<String, dynamic>>? alarmConfigs,
  List<Map<String, dynamic>>? alarmHistory,
}) async {
  final assetJson = asset.toJson();
  final assetKey = assetJson['key'] as String?;

  // Use PlcContextService output if provided; fall back to old PlcCodeIndex path.
  final bool hasPlcContext = plcContext != null &&
      (plcContext.resolvedKeys.isNotEmpty || plcContext.unresolvedKeys.isNotEmpty);

  // Fetch PLC code in parallel with tech doc and drawing lookups.
  final plcBlocksFuture = hasPlcContext
      ? Future.value(<PlcCodeBlock>[])
      : _fetchPlcCodeForAsset(assetKey, plcCodeIndex);

  // Fetch relevant electrical drawings for asset keys in parallel.
  final assetKeys = (asset is BaseAsset) ? List<String>.from(asset.allKeys) : <String>[];
  if (assetKeys.isEmpty && assetKey != null && assetKey.isNotEmpty) {
    assetKeys.add(assetKey);
  }
  final drawingResultsFuture = fetchDrawingsForAsset(assetKeys, drawingIndex);

  // Fast path: no tech doc linked or no index available.
  final techDocId = (asset is BaseAsset) ? asset.techDocId : null;
  final bool hasTechDoc = techDocId != null && techDocIndex != null;

  List<TechDocSection> sections = [];
  String? docName;
  if (hasTechDoc) {
    try {
      final summaries = await techDocIndex.getSummary();
      final doc = summaries.where((s) => s.id == techDocId).firstOrNull;
      docName = doc?.name;
      sections = await techDocIndex.getSectionsForDoc(techDocId);
    } catch (_) {
      // DB error -- sections stays empty.
    }
  }

  final plcBlocks = await plcBlocksFuture;
  final plcSection = hasPlcContext
      ? buildPlcContextSection(plcContext!)
      : _buildPlcCodeSection(plcBlocks);

  final drawingResults = await drawingResultsFuture;
  final drawingSection = buildDrawingContextSection(drawingResults);
  final hasDrawings = drawingSection.isNotEmpty;

  final alarmSection = buildAlarmDefinitionsSection(
    alarmConfigs ?? [],
    alarmHistory ?? [],
  );
  final hasAlarms = alarmSection.isNotEmpty;

  final liveSection = buildLiveValuesSection(liveValues);
  final hasLiveValues = liveValues != null && liveValues.isNotEmpty;

  // If we have no enrichment data at all, fall back to sync version.
  if (sections.isEmpty && plcSection.isEmpty && !hasLiveValues && !hasDrawings && !hasAlarms) {
    return buildDebugAssetMessage(asset);
  }

  final identifier = extractAssetIdentifier(asset);
  final contextBlock = buildAssetContextBlock(asset);

  // Build the tech doc reference block with section titles and content.
  final techBuf = StringBuffer();
  if (sections.isNotEmpty) {
    techBuf.writeln('[TECHNICAL REFERENCE - already fetched, do NOT call search_tech_docs or get_tech_doc_section]');
    techBuf.writeln('Document: ${docName ?? "Tech Doc #$techDocId"}');
    techBuf.writeln('Sections: ${sections.length}');
    techBuf.writeln('');
    for (final section in sections) {
      final indent = '  ' * (section.level - 1);
      techBuf.writeln('${indent}## ${section.title} (pp. ${section.pageStart}-${section.pageEnd})');
      if (section.content.isNotEmpty) {
        // Indent content to match section level for readability.
        final contentLines = section.content.split('\n');
        // Cap at ~200 lines per section to avoid excessively large prompts.
        final cappedLines = contentLines.length > 200
            ? [...contentLines.take(200), '... (truncated, ${contentLines.length - 200} more lines)']
            : contentLines;
        for (final line in cappedLines) {
          techBuf.writeln('$indent$line');
        }
      }
      techBuf.writeln('');
    }
    techBuf.writeln('[END TECHNICAL REFERENCE]');
  }

  // Build the "still need to gather" list, omitting items we already have.
  final todoItems = <String>[];
  if (!hasLiveValues) {
    todoItems.add('- Live tag values (use get_tag_value for the key above)');
  }
  if (!hasAlarms) {
    todoItems.add('- Recent alarm history (use query_alarm_history)');
  }
  if (!hasDrawings) {
    todoItems.add('- Available electrical drawings (use search_drawings)');
  }
  if (plcSection.isEmpty) {
    todoItems.add('- Related PLC code blocks (use search_plc_code)');
  }
  if (sections.isEmpty) {
    todoItems.add('- Technical documentation (use search_tech_docs, then get_tech_doc_section)');
  }

  final alreadyProvided = <String>['configuration'];
  if (hasLiveValues) alreadyProvided.add('live tag values');
  if (sections.isNotEmpty) alreadyProvided.add('technical documentation');
  if (plcSection.isNotEmpty) alreadyProvided.add('PLC code');
  if (hasDrawings) alreadyProvided.add('electrical drawings');
  if (hasAlarms) alreadyProvided.add('alarm definitions');

  // Concatenate all context sections with separating newlines.
  final contextSections = [
    techBuf.toString(),
    plcSection,
    drawingSection,
    alarmSection,
    liveSection,
  ].where((s) => s.isNotEmpty).join('\n');

  // When all context is pre-computed, tell the LLM to answer from
  // the provided data. It may still call get_plc_code_block if needed.
  final bool allContextProvided = todoItems.isEmpty;

  final String instruction;
  if (allContextProvided) {
    instruction = '''[IMPORTANT INSTRUCTION]
ALL diagnostic context for this asset has been pre-computed and is provided above.
The call graph shows key relationships. Use the pre-computed context first.
Use get_plc_code_block(block_name) to fetch full source for any block if needed.
DO NOT call get_tag_value, list_assets, search_plc_code, query_alarm_history,
diagnose_asset, search_drawings, search_tech_docs, or other tools.

Answer the user's question directly using the context provided above.
Provide a focused diagnostic summary of the current state of this asset.
[END INSTRUCTION]''';
  } else {
    instruction = '''The ${alreadyProvided.join(', ')} above ${alreadyProvided.length == 1 ? 'is' : 'are'} already provided — do NOT re-fetch ${alreadyProvided.length == 1 ? 'it' : 'any of them'} with tools.
Use get_plc_code_block(block_name) to fetch full source for any block if needed.
You still need to gather ONLY the following (nothing else):
${todoItems.join('\n')}
Then provide a diagnostic summary of the current state of this asset.''';
  }

  return '''Debug asset: $identifier

$contextBlock
$contextSections
$instruction''';
}

/// Shows a context menu at [globalPosition] with a "Debug this asset" action.
///
/// When the user selects "Debug this asset", calls [onDebug].
Future<void> showAssetContextMenu(
  BuildContext context,
  Offset globalPosition,
  VoidCallback onDebug,
) async {
  final result = await showMenu<String>(
    context: context,
    useRootNavigator: true,
    clipBehavior: Clip.antiAlias,
    position: RelativeRect.fromLTRB(
      globalPosition.dx,
      globalPosition.dy,
      globalPosition.dx,
      globalPosition.dy,
    ),
    items: [
      const PopupMenuItem<String>(
        value: 'debug',
        child: ListTile(
          leading: Icon(Icons.bug_report),
          title: Text('Debug this asset'),
          dense: true,
        ),
      ),
    ],
  );
  if (result == 'debug') {
    onDebug();
  }
}

/// Builds a short visible prompt for configuring an asset.
String buildConfigureAssetPrompt(Asset asset) {
  final identifier = extractAssetIdentifier(asset);
  return 'Help me configure asset "$identifier" - suggest key mappings and settings\n\nUser input: ';
}

/// Builds the LLM instructions for configuring an asset (appended as context).
String buildConfigureAssetInstructions(Asset asset) {
  final identifier = extractAssetIdentifier(asset);
  return '''The current configuration is provided in the context above. Please suggest improvements by:
- Listing available tags that match this asset (use list_tags filtered by "$identifier")
- Suggesting key mappings based on the asset type and available tags
- Recommending any alarm thresholds or display settings

Provide a step-by-step configuration recommendation.''';
}

/// Builds a short visible prompt for explaining an asset type.
String buildExplainAssetPrompt(Asset asset) {
  final identifier = extractAssetIdentifier(asset);
  final assetType = asset.displayName;
  return 'Explain the "$assetType" asset type (asset: "$identifier")';
}

/// Builds the LLM instructions for explaining an asset type (appended as context).
String buildExplainAssetInstructions() {
  return '''Please describe:
- What this asset type displays and how it works
- What key mappings it needs and what each key controls
- Typical use cases and configuration patterns
- Any tips or best practices for using this asset type effectively''';
}

/// Returns the standard AI context menu items for an asset in the page editor
/// edit mode.
///
/// Includes:
/// - **Configure with AI** -- prefills a configuration help prompt for review
/// - **Explain asset type** -- prefills a prompt asking the LLM to explain the
///   asset type, its key mappings, and typical use cases
///
/// Both items attach the asset context block as hidden context, shown as a
/// small chip indicator in the chat input area.
List<AiMenuItem> buildEditorAssetMenuItems(Asset asset) {
  final identifier = extractAssetIdentifier(asset);
  final contextBlock = buildAssetContextBlock(asset);
  final instructions = buildConfigureAssetInstructions(asset);
  final explainInstructions = buildExplainAssetInstructions();

  return [
    AiMenuItem(
      label: 'Configure with AI',
      prefillText: buildConfigureAssetPrompt(asset),
      icon: Icons.settings_suggest,
      contextBlock: '$contextBlock\n$instructions',
      contextLabel: identifier,
      contextType: ChatContextType.asset,
    ),
    AiMenuItem(
      label: 'Explain asset type',
      prefillText: buildExplainAssetPrompt(asset),
      icon: Icons.help_outline,
      contextBlock: '$contextBlock\n$explainInstructions',
      contextLabel: identifier,
      contextType: ChatContextType.asset,
    ),
  ];
}

/// Shows a context menu at [globalPosition] with AI actions for an asset in
/// the page editor's edit mode.
///
/// Menu items include "Configure with AI" and "Explain asset type".
/// Uses [AiContextAction.showMenuAndChat] for the full flow.
///
/// No-op when MCP is not available.
Future<void> showEditorAssetContextMenu(
  BuildContext context,
  WidgetRef ref,
  Offset globalPosition,
  Asset asset,
) async {
  await AiContextAction.showMenuAndChat(
    context: context,
    ref: ref,
    position: globalPosition,
    menuItems: buildEditorAssetMenuItems(asset),
  );
}

/// Opens the chat overlay and sends a debug diagnostic message for [asset].
///
/// No-op in a build with chat compiled out ([kChatEnabled] false).
/// Otherwise:
/// 1. Opens the chat overlay IMMEDIATELY with a loading placeholder
/// 2. Resolves PLC context for all asset keys (if PlcContextService available)
/// 3. Reads live tag values from StateMan for all asset keys
/// 4. Fetches linked tech doc content (if [BaseAsset.techDocId] is set)
/// 5. Updates the context provider with the full diagnostic context
Future<void> debugAsset(WidgetRef ref, Asset asset) async {
  final identifier = extractAssetIdentifier(asset);

  // Open chat immediately so the user sees something right away.
  final opened = await AiContextAction.openChat(
    ref: ref,
    prefillText: 'Diagnose this asset',
    context: ChatContext(
      label: '$identifier (loading context...)',
      type: ChatContextType.asset,
      contextBlock: '[Loading asset context...]',
    ),
  );
  if (!opened) return;

  // Now gather the full context in the background.
  final techDocIndex = ref.read(techDocIndexProvider);
  final plcCodeIndex = ref.read(plcCodeIndexProvider);

  // Resolve PLC context for all asset keys (graceful: null on failure).
  PlcContext? plcContext;
  List<String> allKeys = [];
  try {
    if (asset is BaseAsset) {
      allKeys = List<String>.from(asset.allKeys);
    }
    // For keyless assets (Icon, Arrow, etc.), extract tag references from
    // boolean expression formulas (e.g., conditional state expressions).
    if (allKeys.isEmpty) {
      final exprTags = extractExpressionTags(asset.toJson());
      allKeys.addAll(exprTags);
    }
    // Resolve $variable substitution keys before PLC context lookup.
    if (allKeys.any((k) => k.contains(r'$'))) {
      try {
        final stateMan = await ref.read(stateManProvider.future);
        allKeys = resolveVariableKeys(allKeys, stateMan.substitutions);
      } catch (_) {
        // StateMan unavailable -- keep literal keys (graceful degradation).
      }
    }
    final plcContextService = ref.read(plcContextServiceProvider);
    if (plcContextService != null && allKeys.isNotEmpty) {
      plcContext = await plcContextService.resolveKeys(allKeys);
    }
  } catch (_) {
    // PLC context unavailable -- proceed without it.
  }

  // Read live tag values from StateMan (graceful: empty map on failure).
  Map<String, String>? liveValues;
  if (allKeys.isNotEmpty) {
    try {
      final stateMan = await ref.read(stateManProvider.future);
      final values = await stateMan.readMany(allKeys);
      if (values.isNotEmpty) {
        liveValues = values.map((k, v) => MapEntry(k, v.toString()));
      }
    } catch (_) {
      // StateMan unavailable or keys unreadable -- proceed without live values.
    }
  }

  final drawingIdx = ref.read(drawingIndexProvider);

  // Fetch alarm definitions matching asset keys (in-memory, no DB query).
  List<Map<String, dynamic>>? alarmConfigs;
  try {
    final alarmMan = await ref.read(alarmManProvider.future);
    final allAlarmMaps = alarmMan.config.alarms.map((a) => {
      'uid': a.uid,
      'key': a.key ?? '',
      'title': a.title,
      'description': a.description,
      'rules': a.rules.map((r) => {
        'level': r.level.name,
        'expression': r.expression.value.formula,
      }).toList(),
    }).toList();
    alarmConfigs = filterAlarmConfigsByKeys(allAlarmMaps, allKeys);
  } catch (_) {
    // AlarmMan unavailable -- proceed without alarm context.
  }

  final message = await buildDebugAssetMessageWithTechDoc(
    asset,
    techDocIndex,
    plcCodeIndex: plcCodeIndex,
    plcContext: plcContext,
    liveValues: liveValues,
    drawingIndex: drawingIdx,
    alarmConfigs: alarmConfigs,
  );

  // Update the context provider with the full gathered context.
  ref.read(chatContextProvider.notifier).state = ChatContext(
    label: identifier,
    type: ChatContextType.asset,
    contextBlock: message,
  );
}
