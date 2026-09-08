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
/// Returns [McpConfig.defaults] when no config exists yet — every tool group
/// off, and the blob written back so the next read is the fast path. A device
/// nobody has configured serves nothing until somebody configures it.
///
/// **This writes, and it writes to whatever [prefs] is.** The migration
/// persists its result, so handing this a shared store would put `mcp.config`
/// back in the shared database — the one thing
/// [migrateMcpConfigToDeviceLocal] exists to undo. Every caller passes the
/// device-local store today (`mcp_bridge.dart`'s `mcpConfigProvider`), and
/// that is a property of the call sites rather than of this function, so it
/// is worth re-checking before adding one.
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

/// Where a server process's tool toggles came from.
enum StartupToggleSource {
  /// Handed down in [kMcpTogglesEnvVar] by whatever spawned the process.
  environment,

  /// Given explicitly on the command line with `--toggles`.
  commandLine,

  /// Nothing was handed down at all.
  absent,

  /// Something was handed down and could not be read as toggle JSON.
  unreadable,
}

/// The outcome of resolving a server process's tool toggles at startup.
class StartupToggles {
  const StartupToggles({required this.toggles, required this.source});

  /// The toggles the process should run with.
  final McpToolToggles toggles;

  /// Where [toggles] came from.
  final StartupToggleSource source;

  /// Whether somebody actually decided what this process should serve.
  ///
  /// False means [toggles] is [McpToolToggles.allDisabled] because the
  /// decision is missing, not because anybody chose to disable everything.
  bool get decided =>
      source == StartupToggleSource.environment ||
      source == StartupToggleSource.commandLine;

  /// The line to put on stderr when [decided] is false, or null when it is.
  String? get explanation => switch (source) {
        StartupToggleSource.environment => null,
        StartupToggleSource.commandLine => null,
        StartupToggleSource.absent => kNoTogglesMessage,
        StartupToggleSource.unreadable => kUnreadableTogglesMessage,
      };
}

/// Why a server that was told nothing serves nothing.
///
/// Printed straight to stderr rather than through the logger, because
/// `CENTROID_LOG_LEVEL` must not be able to hide the one line that explains
/// a tool list with nothing in it.
///
/// Says "no tools but `ping`" rather than "no tools", and the precision is
/// the point: somebody reading this is looking at a client that lists one
/// tool. Told to expect an empty list, they would conclude the closed start
/// had failed and go looking for a bug. [resolveStartupToggles] carries the
/// full note.
const kNoTogglesMessage =
    'tfc_mcp_server: no tool toggles were handed down, so every tool group '
    'is disabled and this server offers no tools but the ping health '
    'check.\n'
    '  The MCP config is device-local: the HMI that spawns this server '
    'passes its own decision in $kMcpTogglesEnvVar.\n'
    '  A standalone launch has no station to inherit from and must say so '
    'itself, in that variable or in --toggles. See --help.\n'
    '  This is not a database problem. An absent decision is not a decision '
    'to enable.';

/// Why a server that was told something unreadable serves nothing.
const kUnreadableTogglesMessage =
    'tfc_mcp_server: the tool toggles handed down could not be read as JSON, '
    'so every tool group is disabled and this server offers no tools but '
    'the ping health check.\n'
    '  Check the value of $kMcpTogglesEnvVar, or of --toggles, in whatever '
    'launched this process. See --help for the expected shape.';

/// The `--help` section explaining how a server process is told what to
/// serve, so a standalone launch is an explicit opt-in rather than something
/// inherited from a table.
final kTogglesHelpText = '''
Tool groups:
  Until it is told which tool groups to serve, this server registers none of
  them and offers no tools but its ping health check. The HMI that spawns it
  passes its own device-local decision in $kMcpTogglesEnvVar. A standalone
  launch -- Claude Desktop on a laptop -- has no station to inherit that
  from, and has to say so itself.

  The value is a JSON object mapping group names to booleans. A group is
  served only if the object says so: one left out is off, exactly like one
  set to false, so name every group you want.
  Group names: ${McpToolToggles.allJsonKeys.join(', ')}

  Example: --toggles '{"tags":true,"alarms":true}' -- those two, nothing else.

  The environment variable wins over --toggles, so a spawning app is never
  overridden by a stale shell alias.''';

/// Decides which tool groups a server process serves.
///
/// [envJson] is the raw [kMcpTogglesEnvVar] value and [cliJson] the raw
/// `--toggles` option; the environment wins, so an app spawn is never
/// overridden by a stale shell alias.
///
/// There is deliberately no database fallback. The MCP config is
/// device-local — the deciding device owns it — so the only source that
/// respects that is the decider handing the decision down. A server process
/// cannot read a device-local preference it has no station identity for, and
/// the shared row it used to read is the stale copy the migration deletes.
///
/// With nothing readable, the result is [McpToolToggles.allDisabled] and
/// [StartupToggles.decided] is false. Closed, still running, and able to say
/// why: a stdio server that appears and explains itself is diagnosable in the
/// client, where a refused start is a connection error and a stack trace.
///
/// ## What a closed start looks like from a client
///
/// None of the nine tool groups register, so the server offers **zero domain
/// tools** — the whole SAFE-03/04 surface. It is not a literally empty list:
/// `ping` is registered outside every toggle branch (`server.dart`, "health
/// check, not a domain tool group") and a closed server still answers it.
///
/// That is deliberate, and it is the same argument that chose fail-closed
/// over refuse-to-start. On the security axis those two are tied — both are
/// shut — so what decided it was legibility: a process that starts and says
/// why is diagnosable where a refused connection is a stack trace. A server
/// answering `ping` while listing no domain tools separates "closed on
/// purpose" from "wedged". One answering nothing at all collapses those two
/// states back together and gives back part of what the ruling bought.
///
/// Prose elsewhere — the phase brief, addendum 2 of the core review — says
/// "serves the empty tool list". Read that as zero domain tools. An operator
/// told to expect a literally empty list will see one entry and conclude the
/// fix failed.
StartupToggles resolveStartupToggles({String? envJson, String? cliJson}) {
  // Each source in turn, most authoritative first. A source that spoke and
  // was not understood ends the search: reading past it to a lesser source
  // would serve tools the spawner never asked for, which is the fail-open
  // this function exists to close.
  final supplied = <(String, StartupToggleSource)>[
    if (envJson != null && envJson.isNotEmpty)
      (envJson, StartupToggleSource.environment),
    if (cliJson != null && cliJson.isNotEmpty)
      (cliJson, StartupToggleSource.commandLine),
  ];

  if (supplied.isEmpty) {
    return const StartupToggles(
      toggles: McpToolToggles.allDisabled,
      source: StartupToggleSource.absent,
    );
  }

  final (json, source) = supplied.first;
  final toggles = togglesFromEnvJson(json);

  if (toggles == null) {
    // Its own message on purpose: a typo in a client config is a different
    // errand from a variable nobody set, and the reader has to be sent to
    // the right one.
    return const StartupToggles(
      toggles: McpToolToggles.allDisabled,
      source: StartupToggleSource.unreadable,
    );
  }

  return StartupToggles(toggles: toggles, source: source);
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

  // Drop every MCP key from the shared store.
  await shared.remove(McpConfig.kPrefKey);
  for (final key in McpConfig.legacyKeys) {
    await shared.remove(key);
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
    tagsEnabled: await readBool(McpToolToggles.kTagsEnabled) ?? false,
    alarmsEnabled: await readBool(McpToolToggles.kAlarmsEnabled) ?? false,
    configEnabled: await readBool(McpToolToggles.kConfigEnabled) ?? false,
    drawingsEnabled: await readBool(McpToolToggles.kDrawingsEnabled) ?? false,
    trendsEnabled: await readBool(McpToolToggles.kTrendsEnabled) ?? false,
    plcCodeEnabled: await readBool(McpToolToggles.kPlcCodeEnabled) ?? false,
    proposalsEnabled: await readBool(McpToolToggles.kProposalsEnabled) ?? false,
    techDocsEnabled: await readBool(McpToolToggles.kTechDocsEnabled) ?? false,
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
    tagsEnabled: await prefs.getBool(McpToolToggles.kTagsEnabled) ?? false,
    alarmsEnabled: await prefs.getBool(McpToolToggles.kAlarmsEnabled) ?? false,
    configEnabled: await prefs.getBool(McpToolToggles.kConfigEnabled) ?? false,
    drawingsEnabled:
        await prefs.getBool(McpToolToggles.kDrawingsEnabled) ?? false,
    trendsEnabled: await prefs.getBool(McpToolToggles.kTrendsEnabled) ?? false,
    plcCodeEnabled:
        await prefs.getBool(McpToolToggles.kPlcCodeEnabled) ?? false,
    proposalsEnabled:
        await prefs.getBool(McpToolToggles.kProposalsEnabled) ?? false,
    techDocsEnabled:
        await prefs.getBool(McpToolToggles.kTechDocsEnabled) ?? false,
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
