/// Consolidated MCP configuration stored as a single JSON blob.
///
/// Replaces the individual preference keys (`mcp_server_enabled`,
/// `mcp_chat_enabled`, `mcp_server_port`, `mcp_tools_*_enabled`) with a
/// single JSON object under [McpConfig.kPrefKey].
///
/// On first load, [McpConfig.readFromPreferences] migrates any legacy
/// individual keys into the struct, so existing installations upgrade
/// transparently.
class McpConfig {
  /// The single preference key for the consolidated MCP config JSON.
  static const kPrefKey = 'mcp.config';

  /// Whether the MCP HTTP server is enabled (Streamable HTTP for Claude Desktop).
  final bool serverEnabled;

  /// Whether the in-app AI chat bubble is shown.
  final bool chatEnabled;

  /// The port for the MCP HTTP server.
  final int port;

  /// Tool group toggle configuration.
  final McpToolToggles toggles;

  /// Default port for new installations.
  static const defaultPort = 8765;

  const McpConfig({
    this.serverEnabled = false,
    this.chatEnabled = false,
    this.port = defaultPort,
    this.toggles = McpToolToggles.allDisabled,
  });

  /// Default config for new installations.
  static const defaults = McpConfig();

  /// Deserialize from a JSON map.
  ///
  /// Missing keys fall back to defaults so that adding new fields in future
  /// versions is backwards-compatible.
  factory McpConfig.fromJson(Map<String, dynamic> json) {
    return McpConfig(
      serverEnabled: json['serverEnabled'] as bool? ?? false,
      chatEnabled: json['chatEnabled'] as bool? ?? false,
      port: json['port'] as int? ?? defaultPort,
      toggles: json['toggles'] is Map<String, dynamic>
          ? McpToolToggles.fromJson(json['toggles'] as Map<String, dynamic>)
          : McpToolToggles.allDisabled,
    );
  }

  /// Serialize to a JSON map.
  Map<String, dynamic> toJson() => {
        'serverEnabled': serverEnabled,
        'chatEnabled': chatEnabled,
        'port': port,
        'toggles': toggles.toJson(),
      };

  /// Returns a copy with the specified fields replaced.
  McpConfig copyWith({
    bool? serverEnabled,
    bool? chatEnabled,
    int? port,
    McpToolToggles? toggles,
  }) {
    return McpConfig(
      serverEnabled: serverEnabled ?? this.serverEnabled,
      chatEnabled: chatEnabled ?? this.chatEnabled,
      port: port ?? this.port,
      toggles: toggles ?? this.toggles,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is McpConfig &&
      other.serverEnabled == serverEnabled &&
      other.chatEnabled == chatEnabled &&
      other.port == port &&
      other.toggles == toggles;

  @override
  int get hashCode => Object.hash(serverEnabled, chatEnabled, port, toggles);

  /// Legacy preference keys used before consolidation.
  ///
  /// Used by migration logic and the toggle-change listener to detect
  /// when this config needs to be reloaded.
  static const _legacyServerEnabled = 'mcp_server_enabled';
  static const _legacyChatEnabled = 'mcp_chat_enabled';
  static const _legacyServerPort = 'mcp_server_port';

  /// All legacy keys (server + chat + port + tool toggles).
  static const legacyKeys = [
    _legacyServerEnabled,
    _legacyChatEnabled,
    _legacyServerPort,
    ...McpToolToggles.legacyKeys,
  ];
}

/// Configuration for which MCP tool groups are enabled.
///
/// All groups default to **false**. A group is served because somebody
/// turned it on, never because nobody turned it off: these gate the
/// SAFE-03/04 surface, and on that surface an absent decision is undecided
/// rather than yes. Disabled groups are not registered on the MCP server and
/// are invisible to the LLM.
///
/// This is a change in behaviour for an install that predates it. A stored
/// blob written before a group existed has no key for that group, so the
/// group reads as off after upgrading and has to be switched on in settings.
/// Only `screenshots` is actually in that position — see [allJsonKeys].
class McpToolToggles {
  final bool tagsEnabled;
  final bool alarmsEnabled;
  final bool configEnabled;
  final bool drawingsEnabled;
  final bool trendsEnabled;
  final bool plcCodeEnabled;
  final bool proposalsEnabled;
  final bool techDocsEnabled;
  final bool screenshotsEnabled;
  final bool reportsEnabled;

  const McpToolToggles({
    this.tagsEnabled = false,
    this.alarmsEnabled = false,
    this.configEnabled = false,
    this.drawingsEnabled = false,
    this.trendsEnabled = false,
    this.plcCodeEnabled = false,
    this.proposalsEnabled = false,
    this.techDocsEnabled = false,
    this.screenshotsEnabled = false,
    this.reportsEnabled = false,
  });

  /// All groups enabled.
  ///
  /// Spelled out rather than `McpToolToggles()`, which it used to be: the
  /// constructor defaults every field to `false` now, so the bare form is
  /// [allDisabled]. Writing it out is what keeps this constant meaning what
  /// its name says the day a tenth group is added.
  static const allEnabled = McpToolToggles(
    tagsEnabled: true,
    alarmsEnabled: true,
    configEnabled: true,
    drawingsEnabled: true,
    trendsEnabled: true,
    plcCodeEnabled: true,
    proposalsEnabled: true,
    techDocsEnabled: true,
    screenshotsEnabled: true,
    reportsEnabled: true,
  );

  /// All groups disabled: what everything resolves to until somebody says
  /// otherwise.
  ///
  /// This is the plain default, not a special case. `McpToolToggles()` is
  /// this value, an empty JSON object deserializes to it, and a server
  /// process whose spawner handed down no toggles runs as it. That was not
  /// true when this constant was introduced — every field then defaulted to
  /// `true`, and this existed only for the undecided-spawner case — and the
  /// change is deliberate: a capability surface should be opened on purpose,
  /// so absence resolves here for stored config exactly as it already did
  /// for a missing decision.
  static const allDisabled = McpToolToggles(
    tagsEnabled: false,
    alarmsEnabled: false,
    configEnabled: false,
    drawingsEnabled: false,
    trendsEnabled: false,
    plcCodeEnabled: false,
    proposalsEnabled: false,
    techDocsEnabled: false,
    screenshotsEnabled: false,
  );

  @override
  bool operator ==(Object other) =>
      other is McpToolToggles &&
      other.tagsEnabled == tagsEnabled &&
      other.alarmsEnabled == alarmsEnabled &&
      other.configEnabled == configEnabled &&
      other.drawingsEnabled == drawingsEnabled &&
      other.trendsEnabled == trendsEnabled &&
      other.plcCodeEnabled == plcCodeEnabled &&
      other.proposalsEnabled == proposalsEnabled &&
      other.techDocsEnabled == techDocsEnabled &&
      other.screenshotsEnabled == screenshotsEnabled &&
      other.reportsEnabled == reportsEnabled;

  @override
  int get hashCode => Object.hash(
        tagsEnabled,
        alarmsEnabled,
        configEnabled,
        drawingsEnabled,
        trendsEnabled,
        plcCodeEnabled,
        proposalsEnabled,
        techDocsEnabled,
        screenshotsEnabled,
        reportsEnabled,
      );

  // ── JSON field names (used in the consolidated McpConfig blob) ──────

  static const _kTags = 'tags';
  static const _kAlarms = 'alarms';
  static const _kConfig = 'config';
  static const _kDrawings = 'drawings';
  static const _kTrends = 'trends';
  static const _kPlcCode = 'plcCode';
  static const _kProposals = 'proposals';
  static const _kTechDocs = 'techDocs';
  static const _kScreenshots = 'screenshots';
  static const _kReports = 'reports';

  // ── Legacy preference key constants (pre-consolidation) ─────────────

  static const kTagsEnabled = 'mcp_tools_tags_enabled';
  static const kAlarmsEnabled = 'mcp_tools_alarms_enabled';
  static const kConfigEnabled = 'mcp_tools_config_enabled';
  static const kDrawingsEnabled = 'mcp_tools_drawings_enabled';
  static const kTrendsEnabled = 'mcp_tools_trends_enabled';
  static const kPlcCodeEnabled = 'mcp_tools_plc_code_enabled';
  static const kProposalsEnabled = 'mcp_tools_proposals_enabled';
  static const kTechDocsEnabled = 'mcp_tools_tech_docs_enabled';
  static const kScreenshotsEnabled = 'mcp_tools_screenshots_enabled';

  /// All legacy preference keys for migration.
  static const legacyKeys = [
    kTagsEnabled,
    kAlarmsEnabled,
    kConfigEnabled,
    kDrawingsEnabled,
    kTrendsEnabled,
    kPlcCodeEnabled,
    kProposalsEnabled,
    kTechDocsEnabled,
    kScreenshotsEnabled,
  ];

  /// All JSON field names for the toggles sub-object.
  static const allJsonKeys = [
    _kTags,
    _kAlarms,
    _kConfig,
    _kDrawings,
    _kTrends,
    _kPlcCode,
    _kProposals,
    _kTechDocs,
    _kScreenshots,
    _kReports,
  ];

  /// Create toggles from a JSON map (within the McpConfig blob).
  ///
  /// Missing keys default to `false` (disabled): a blob that never named a
  /// group is a blob in which nobody enabled it.
  factory McpToolToggles.fromJson(Map<String, dynamic> json) {
    return McpToolToggles(
      tagsEnabled: json[_kTags] as bool? ?? false,
      alarmsEnabled: json[_kAlarms] as bool? ?? false,
      configEnabled: json[_kConfig] as bool? ?? false,
      drawingsEnabled: json[_kDrawings] as bool? ?? false,
      trendsEnabled: json[_kTrends] as bool? ?? false,
      plcCodeEnabled: json[_kPlcCode] as bool? ?? false,
      proposalsEnabled: json[_kProposals] as bool? ?? false,
      techDocsEnabled: json[_kTechDocs] as bool? ?? false,
      screenshotsEnabled: json[_kScreenshots] as bool? ?? false,
      reportsEnabled: json[_kReports] as bool? ?? false,
    );
  }

  /// Serialize to a JSON map.
  Map<String, dynamic> toJson() => {
        _kTags: tagsEnabled,
        _kAlarms: alarmsEnabled,
        _kConfig: configEnabled,
        _kDrawings: drawingsEnabled,
        _kTrends: trendsEnabled,
        _kPlcCode: plcCodeEnabled,
        _kProposals: proposalsEnabled,
        _kTechDocs: techDocsEnabled,
        _kScreenshots: screenshotsEnabled,
        _kReports: reportsEnabled,
      };

  /// Create toggles from a map of legacy preference keys to boolean values.
  ///
  /// Missing keys default to `false` (disabled), for the same reason
  /// [fromJson]'s do. Used during migration from individual preference keys.
  factory McpToolToggles.fromLegacyMap(Map<String, bool> map) {
    return McpToolToggles(
      tagsEnabled: map[kTagsEnabled] ?? false,
      alarmsEnabled: map[kAlarmsEnabled] ?? false,
      configEnabled: map[kConfigEnabled] ?? false,
      drawingsEnabled: map[kDrawingsEnabled] ?? false,
      trendsEnabled: map[kTrendsEnabled] ?? false,
      plcCodeEnabled: map[kPlcCodeEnabled] ?? false,
      proposalsEnabled: map[kProposalsEnabled] ?? false,
      techDocsEnabled: map[kTechDocsEnabled] ?? false,
      screenshotsEnabled: map[kScreenshotsEnabled] ?? false,
    );
  }

  /// Returns a copy with a single toggle changed by its JSON key name.
  McpToolToggles copyWithToggle(String jsonKey, bool value) {
    return McpToolToggles(
      tagsEnabled: jsonKey == _kTags ? value : tagsEnabled,
      alarmsEnabled: jsonKey == _kAlarms ? value : alarmsEnabled,
      configEnabled: jsonKey == _kConfig ? value : configEnabled,
      drawingsEnabled: jsonKey == _kDrawings ? value : drawingsEnabled,
      trendsEnabled: jsonKey == _kTrends ? value : trendsEnabled,
      plcCodeEnabled: jsonKey == _kPlcCode ? value : plcCodeEnabled,
      proposalsEnabled: jsonKey == _kProposals ? value : proposalsEnabled,
      techDocsEnabled: jsonKey == _kTechDocs ? value : techDocsEnabled,
      screenshotsEnabled:
          jsonKey == _kScreenshots ? value : screenshotsEnabled,
      reportsEnabled: jsonKey == _kReports ? value : reportsEnabled,
    );
  }

  /// Gets the value of a toggle by its JSON key name.
  bool getByKey(String jsonKey) {
    switch (jsonKey) {
      case _kTags:
        return tagsEnabled;
      case _kAlarms:
        return alarmsEnabled;
      case _kConfig:
        return configEnabled;
      case _kDrawings:
        return drawingsEnabled;
      case _kTrends:
        return trendsEnabled;
      case _kPlcCode:
        return plcCodeEnabled;
      case _kProposals:
        return proposalsEnabled;
      case _kTechDocs:
        return techDocsEnabled;
      case _kScreenshots:
        return screenshotsEnabled;
      case _kReports:
        return reportsEnabled;
      default:
        // An unknown group is one nobody decided about, and undecided on a
        // capability surface is off.
        return false;
    }
  }

  /// Metadata for rendering SwitchListTile widgets in the preferences UI.
  ///
  /// Each entry contains the JSON key, a human-readable title, and a
  /// one-line description of what the tool group provides.
  static const toolGroupMeta = [
    (
      key: _kTags,
      title: 'Live Values',
      description: 'Reference live process values when troubleshooting or explaining behavior',
    ),
    (
      key: _kAlarms,
      title: 'Alarms',
      description: 'Troubleshoot using active alarms and alarm history',
    ),
    (
      key: _kConfig,
      title: 'System Config',
      description: 'Answer questions about your pages, assets, keys, and alarm definitions',
    ),
    (
      key: _kDrawings,
      title: 'Electrical Drawings',
      description: 'Trace signals and wiring using electrical diagrams',
    ),
    (
      key: _kTrends,
      title: 'Trend History',
      description: 'Spot patterns and diagnose issues using historical data',
    ),
    (
      key: _kPlcCode,
      title: 'PLC Code',
      description: 'Debug and explain control logic using PLC source code',
    ),
    (
      key: _kProposals,
      title: 'AI Suggestions',
      description: 'Draft new alarms, pages, and assets for you to review before applying',
    ),
    (
      key: _kTechDocs,
      title: 'Tech Docs',
      description: 'Reference equipment manuals and datasheets during diagnostics',
    ),
    (
      key: _kScreenshots,
      title: 'Screen Capture',
      description: 'Let the AI see the HMI screen, so it can judge a layout by eye',
    ),
    (
      key: _kReports,
      title: 'Reports',
      description: 'Generate shift and production reports, and configure report definitions',
    ),
  ];
}
