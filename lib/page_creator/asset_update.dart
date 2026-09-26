import 'dart:convert';
import 'assets/common.dart';
import 'assets/registry.dart';

/// Outcome of applying an `asset_update` MCP proposal to a page's assets.
///
/// Either [updated]/[index] identify the replacement asset, or [error]
/// says why nothing was changed. Never both.
class AssetUpdateResult {
  final Asset? updated;
  final int index;
  final String? error;

  const AssetUpdateResult.success(Asset this.updated, this.index)
      : error = null;
  const AssetUpdateResult.failure(String this.error)
      : updated = null,
        index = -1;
}

/// Resolves an `asset_update` proposal against [assets] and produces the
/// patched replacement.
///
/// The target is matched semantically at apply time -- by `asset_type`,
/// narrowed by `title` (the asset's display text) and/or `key` (its bound
/// tag key) when given -- so a proposal stays valid when the page is
/// reordered between proposing and applying. The match must be unique:
/// zero or several candidates both fail, leaving the page untouched, so a
/// stale proposal can never silently patch the wrong asset.
///
/// An `index` (position in the page's flat assets array, as returned by
/// get_asset_detail) picks between candidates the semantic match cannot
/// tell apart. It is a tie-breaker, never trusted alone: the asset at
/// that position must still satisfy the semantic selector, so an index
/// gone stale through insert/delete/reorder fails loudly instead of
/// patching whatever slid into the slot.
///
/// The patch is a shallow merge onto the asset's JSON (its `asset_name`
/// cannot be changed). With `child_id` set, the patch instead targets the
/// child entry with that stable id inside the asset -- merging into the
/// entry's embedded `child` asset when it has one (ThirdPartyEquipment,
/// Elevator), or the entry itself otherwise.
///
/// The caller is responsible for storing [AssetUpdateResult.updated] back
/// at [AssetUpdateResult.index]; this function does not mutate [assets].
AssetUpdateResult applyAssetUpdate(
  List<Asset> assets,
  Map<String, dynamic> proposal,
) {
  final target = proposal['target'];
  final patch = proposal['patch'];
  if (target is! Map<String, dynamic>) {
    return const AssetUpdateResult.failure('proposal has no target object');
  }
  if (patch is! Map<String, dynamic> || patch.isEmpty) {
    return const AssetUpdateResult.failure('proposal has no patch fields');
  }

  final assetType = target['asset_type'] as String?;
  if (assetType == null) {
    return const AssetUpdateResult.failure('target has no asset_type');
  }
  final title = target['title'] as String?;
  final key = target['key'] as String?;
  final childId = target['child_id'] as String?;
  final targetIndex = target['index'] as int?;

  /// Title match, against the label the operator actually sees.
  ///
  /// `text` is what gets painted on the page, but assets that hide their
  /// label there (ThirdPartyEquipment and Sensor, via `showTag`) return null
  /// from it while `tag` still names them in the side pane, the palette and
  /// the proposal banner. Matching `text` alone made every one of those
  /// unaddressable by title, and the failure surfaced as "the page may have
  /// changed" -- which sends the operator looking for a problem that is not
  /// there.
  bool titleMatches(Asset a) {
    if (a.text == title) return true;
    try {
      return (a as dynamic).tag == title;
    } catch (_) {
      return false;
    }
  }

  bool keyMatches(Asset a) {
    try {
      return (a as dynamic).key == key;
    } catch (_) {
      return false;
    }
  }

  final candidates = <int>[];
  for (var i = 0; i < assets.length; i++) {
    final a = assets[i];
    // The stored name, not `runtimeType.toString()`, which dart2js minifies.
    if (a.assetName != assetType) continue;
    if (title != null && !titleMatches(a)) continue;
    if (key != null && !keyMatches(a)) continue;
    candidates.add(i);
  }

  final selector = [
    assetType,
    if (title != null) 'title "$title"',
    if (key != null) 'key "$key"',
  ].join(', ');

  final int index;
  if (targetIndex != null) {
    if (targetIndex < 0 || targetIndex >= assets.length) {
      return AssetUpdateResult.failure(
          'index $targetIndex is out of range (page has ${assets.length} '
          'assets) -- the page may have changed since the proposal was made');
    }
    if (!candidates.contains(targetIndex)) {
      final actual = assets[targetIndex];
      return AssetUpdateResult.failure(
          'asset at index $targetIndex is ${actual.runtimeType}'
          '${actual.text != null ? ' "${actual.text}"' : ''}, which does not '
          'match $selector -- the page may have changed since the proposal '
          'was made');
    }
    index = targetIndex;
  } else {
    if (candidates.isEmpty) {
      return AssetUpdateResult.failure('no asset matches $selector');
    }
    if (candidates.length > 1) {
      return AssetUpdateResult.failure(
          '${candidates.length} assets match $selector -- add title, key or '
          'index to disambiguate');
    }
    index = candidates.single;
  }
  // Round-trip through JSON rather than using toJson() directly.
  //
  // toJson() is shallow: nested values (coordinates, size, colours, the child
  // assets inside a ThirdPartyEquipment) come back as live objects, not maps.
  // Patching that and handing it to AssetRegistry.parse fails on the first
  // nested field with "type 'Coordinates' is not a subtype of type
  // 'Map<String, dynamic>'". Encoding and decoding forces the whole tree to
  // plain JSON, which is what parse expects.
  final json =
      jsonDecode(jsonEncode(assets[index])) as Map<String, dynamic>;
  // The patch may not switch the asset to a different type.
  final cleanPatch = Map<String, dynamic>.from(patch)..remove(constAssetName);

  if (childId != null) {
    final children = json['children'];
    if (children is! List) {
      return AssetUpdateResult.failure(
          '$assetType has no children to match child_id "$childId"');
    }
    var found = false;
    final newChildren = children.map((c) {
      if (c is! Map<String, dynamic> || c['id'] != childId) return c;
      found = true;
      final childAsset = c['child'];
      if (childAsset is Map<String, dynamic>) {
        return {...c, 'child': {...childAsset, ...cleanPatch}};
      }
      return {...c, ...cleanPatch};
    }).toList();
    if (!found) {
      return AssetUpdateResult.failure(
          'no child with id "$childId" in $selector');
    }
    json['children'] = newChildren;
  } else {
    json.addAll(cleanPatch);
  }
  json[constAssetName] = assetType;

  try {
    final parsed = AssetRegistry.parse({'assets': [json]});
    if (parsed.length != 1) {
      return AssetUpdateResult.failure(
          'patched JSON no longer parses as a $assetType');
    }
    return AssetUpdateResult.success(parsed.single, index);
  } catch (e) {
    return AssetUpdateResult.failure(
        'patched JSON no longer parses as a $assetType: $e');
  }
}
