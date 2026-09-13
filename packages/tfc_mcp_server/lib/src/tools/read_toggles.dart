import 'dart:convert';

import 'package:tfc_dart/core/preferences.dart' show PreferencesApi;

import 'tool_toggles.dart';

/// Reads the current [McpConfig] from preferences.
///
/// On first load, migrates any legacy individual keys
/// (`mcp_server_enabled`, `mcp_chat_enabled`, `mcp_server_port`,
/// `mcp_tools_*_enabled`) into the consolidated [McpConfig.kPrefKey] JSON
/// blob. After migration the legacy keys remain in the database but are
/// no longer read.
///
/// Returns [McpConfig.defaults] when no config exists yet.
Future<McpConfig> readMcpConfigFromPreferences(PreferencesApi prefs) async {
  final json = await prefs.getString(McpConfig.kPrefKey);

  if (json != null) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return McpConfig.fromJson(map);
    } catch (_) {
      // Corrupted JSON -- fall through to migration / defaults.
    }
  }

  // No consolidated config yet -- attempt migration from legacy keys.
  return _migrateFromLegacyKeys(prefs);
}

/// Writes [config] to the single [McpConfig.kPrefKey] preference.
Future<void> writeMcpConfigToPreferences(
  PreferencesApi prefs,
  McpConfig config,
) async {
  final json = jsonEncode(config.toJson());
  await prefs.setString(McpConfig.kPrefKey, json);
}

/// Reads the [McpToolToggles] portion from preferences.
///
/// Convenience wrapper that reads the full [McpConfig] and returns
/// just the toggles. Backwards-compatible signature for callers that
/// only need toggles (e.g. MCP server startup).
Future<McpToolToggles> readTogglesFromPreferences(PreferencesApi prefs) async {
  final config = await readMcpConfigFromPreferences(prefs);
  return config.toggles;
}

/// Environment variable carrying the tool-toggle JSON for a spawned
/// server subprocess.
///
/// The MCP config is device-local, so a subprocess cannot read it from
/// the shared database; the spawning HMI passes the toggles along instead.
const kMcpTogglesEnvVar = 'CENTROIDX_MCP_TOGGLES';

/// Parses [McpToolToggles] from the [kMcpTogglesEnvVar] JSON payload.
///
/// Returns null when [json] is absent or malformed, so callers can fall
/// back to another source.
McpToolToggles? togglesFromEnvJson(String? json) {
  if (json == null || json.isEmpty) return null;
  try {
    final map = jsonDecode(json);
    if (map is! Map<String, dynamic>) return null;
    return McpToolToggles.fromJson(map);
  } catch (_) {
    return null;
  }
}

/// One-time migration of the MCP config from the [shared]
/// (database-backed) preference store to the [local] (device-only) store.
///
/// The MCP config is a per-device setting: each HMI station decides for
/// itself whether to run the MCP server and which tools to expose. This
/// moves any config the shared database still carries onto the device and
/// deletes every MCP key from the database, so the setting no longer leaks
/// across stations.
///
/// A config already present in [local] wins; the [shared] value only seeds
/// a device that has no local config yet. Safe to call repeatedly.
Future<void> migrateMcpConfigToDeviceLocal({
  required PreferencesApi shared,
  required PreferencesApi local,
}) async {
  // Capture the device-local blob first: the database-backed Preferences
  // mirrors removals into its local cache, which is the same physical
  // store as [local] — cleaning [shared] below may erase the key there.
  final localJson = await local.getString(McpConfig.kPrefKey);

  // Read whatever the shared store still carries.
  McpConfig? sharedConfig;
  final sharedJson = await shared.getString(McpConfig.kPrefKey);
  if (sharedJson != null) {
    try {
      sharedConfig =
          McpConfig.fromJson(jsonDecode(sharedJson) as Map<String, dynamic>);
    } catch (_) {
      // Corrupted blob -- nothing worth migrating.
    }
  }
  sharedConfig ??= await _readLegacyConfigIfAny(shared);

  // Drop every MCP key the shared store still carries. Only the ones present:
  // this re-runs on every database reconnect, the app's shared store audits
  // every remove, and removing a key that is already gone wrote a
  // `mcp_tools_…_enabled — → —` row into the audit trail per legacy key, per
  // reconnect, forever after the first migration had done its job.
  for (final key in [McpConfig.kPrefKey, ...McpConfig.legacyKeys]) {
    if (await shared.containsKey(key)) {
      await shared.remove(key);
    }
  }

  if (localJson != null) {
    // Re-write in case cleaning [shared] wiped the mirrored copy.
    await local.setString(McpConfig.kPrefKey, localJson);
  } else if (sharedConfig != null) {
    await writeMcpConfigToPreferences(local, sharedConfig);
  }
}

/// Builds a config from legacy individual keys, or null when none exist.
Future<McpConfig?> _readLegacyConfigIfAny(PreferencesApi prefs) async {
  var found = false;
  Future<bool?> readBool(String key) async {
    final v = await prefs.getBool(key);
    if (v != null) found = true;
    return v;
  }

  final serverEnabled = await readBool('mcp_server_enabled');
  final chatEnabled = await readBool('mcp_chat_enabled');
  final port = await prefs.getInt('mcp_server_port');
  if (port != null) found = true;

  final toggles = McpToolToggles(
    tagsEnabled: await readBool(McpToolToggles.kTagsEnabled) ?? true,
    alarmsEnabled: await readBool(McpToolToggles.kAlarmsEnabled) ?? true,
    configEnabled: await readBool(McpToolToggles.kConfigEnabled) ?? true,
    drawingsEnabled: await readBool(McpToolToggles.kDrawingsEnabled) ?? true,
    trendsEnabled: await readBool(McpToolToggles.kTrendsEnabled) ?? true,
    plcCodeEnabled: await readBool(McpToolToggles.kPlcCodeEnabled) ?? true,
    proposalsEnabled: await readBool(McpToolToggles.kProposalsEnabled) ?? true,
    techDocsEnabled: await readBool(McpToolToggles.kTechDocsEnabled) ?? true,
  );

  if (!found) return null;
  return McpConfig(
    serverEnabled: serverEnabled ?? false,
    chatEnabled: chatEnabled ?? false,
    port: port ?? McpConfig.defaultPort,
    toggles: toggles,
  );
}

/// Migrates legacy individual preference keys into a consolidated
/// [McpConfig] JSON blob.
///
/// Reads each legacy key, constructs the config, writes the consolidated
/// blob, and returns the result. If no legacy keys exist either, returns
/// [McpConfig.defaults].
Future<McpConfig> _migrateFromLegacyKeys(PreferencesApi prefs) async {
  // Read legacy server/chat/port keys.
  final serverEnabled = await prefs.getBool('mcp_server_enabled') ?? false;
  final chatEnabled = await prefs.getBool('mcp_chat_enabled') ?? false;
  final port = await prefs.getInt('mcp_server_port') ?? McpConfig.defaultPort;

  // Read legacy toggle keys.
  final toggles = McpToolToggles(
    tagsEnabled: await prefs.getBool(McpToolToggles.kTagsEnabled) ?? true,
    alarmsEnabled: await prefs.getBool(McpToolToggles.kAlarmsEnabled) ?? true,
    configEnabled: await prefs.getBool(McpToolToggles.kConfigEnabled) ?? true,
    drawingsEnabled:
        await prefs.getBool(McpToolToggles.kDrawingsEnabled) ?? true,
    trendsEnabled: await prefs.getBool(McpToolToggles.kTrendsEnabled) ?? true,
    plcCodeEnabled:
        await prefs.getBool(McpToolToggles.kPlcCodeEnabled) ?? true,
    proposalsEnabled:
        await prefs.getBool(McpToolToggles.kProposalsEnabled) ?? true,
    techDocsEnabled:
        await prefs.getBool(McpToolToggles.kTechDocsEnabled) ?? true,
  );

  final config = McpConfig(
    serverEnabled: serverEnabled,
    chatEnabled: chatEnabled,
    port: port,
    toggles: toggles,
  );

  // Persist the consolidated config so future reads use the fast path.
  await writeMcpConfigToPreferences(prefs, config);

  return config;
}
