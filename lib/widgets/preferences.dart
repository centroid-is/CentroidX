import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:tfc/widgets/panes/database_stats_pane.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:postgres/postgres.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc_mcp_server/tfc_mcp_server.dart'
    show
        McpConfig,
        McpToolToggles,
        writeMcpConfigToPreferences;

import '../core/feature_flags.dart';
import '../core/gateway_config.dart';
import '../core/update_channel.dart';
import '../providers/gateway.dart';
import '../providers/mcp_bridge.dart';
import '../providers/preferences.dart';
import '../providers/theme.dart';
import '../theme.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/database.dart';

/// Appearance settings section for the preferences page.
///
/// Selects the default color scheme ([AppColorScheme], stored under
/// `color_scheme`); light/dark stays on the app-bar brightness toggle.
class AppearanceSection extends ConsumerWidget {
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schemeAsync = ref.watch(colorSchemeNotifierProvider);
    final scheme = schemeAsync.valueOrNull ?? AppColorScheme.solarized;

    return Card(
      child: ListTile(
        leading: const FaIcon(FontAwesomeIcons.palette, size: 20),
        title: const Text('Color Scheme'),
        subtitle: const Text('Default color scheme for the whole app'),
        trailing: DropdownButton<AppColorScheme>(
          value: scheme,
          onChanged: (value) {
            if (value == null) return;
            ref.read(colorSchemeNotifierProvider.notifier).setScheme(value);
          },
          items: [
            for (final option in AppColorScheme.values)
              DropdownMenuItem(
                value: option,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _SchemeSwatches(scheme: option),
                    const SizedBox(width: 8),
                    Text(option.displayName),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Update channel section for the preferences page.
///
/// Chooses which releases the app announces and installs: stable (tagged
/// releases) or latest (the rolling main build, republished on every merge).
/// Stored locally under [updateChannelPrefsKey]; the next update check picks
/// the change up without a restart.
class UpdateSection extends StatefulWidget {
  const UpdateSection({
    super.key,
    this.readChannel = readUpdateChannel,
    this.writeChannel = writeUpdateChannel,
  });

  /// Injectable for tests; defaults to the SharedPreferences-backed helpers.
  final Future<String> Function() readChannel;
  final Future<void> Function(String) writeChannel;

  @override
  State<UpdateSection> createState() => _UpdateSectionState();
}

class _UpdateSectionState extends State<UpdateSection> {
  String _channel = updateChannelStable;

  @override
  void initState() {
    super.initState();
    widget.readChannel().then((value) {
      if (mounted) setState(() => _channel = value);
    });
  }

  Future<void> _select(String? value) async {
    if (value == null) return;
    setState(() => _channel = value);
    await widget.writeChannel(value);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const FaIcon(FontAwesomeIcons.arrowsRotate, size: 20),
            title: const Text('Update Channel'),
            subtitle: Text(
              buildGitSha.isEmpty
                  ? 'Which releases this HMI updates to'
                  : 'Which releases this HMI updates to — build ${buildGitSha.length > 7 ? buildGitSha.substring(0, 7) : buildGitSha}',
            ),
          ),
          RadioGroup<String>(
            groupValue: _channel,
            onChanged: _select,
            child: const Column(
              children: [
                RadioListTile<String>(
                  value: updateChannelStable,
                  title: Text('Stable'),
                  subtitle:
                      Text('Tagged releases that went through release testing'),
                ),
                RadioListTile<String>(
                  value: updateChannelLatest,
                  title: Text('Latest'),
                  subtitle: Text(
                      'Newest development build from main — replaced on every merge, no release testing'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A small strip of the scheme's equipment-state colors, so the dropdown
/// shows what each option looks like before it is applied.
class _SchemeSwatches extends StatelessWidget {
  const _SchemeSwatches({required this.scheme});

  final AppColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final HmiStateColors states = switch (scheme) {
      AppColorScheme.solarized =>
        dark ? HmiStateColors.solarizedDark : HmiStateColors.solarizedLight,
      AppColorScheme.muted =>
        dark ? HmiStateColors.mutedDark : HmiStateColors.mutedLight,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final color in [
          states.green,
          states.yellow,
          states.blue,
          states.grey,
          states.red,
        ])
          Container(
            width: 10,
            height: 14,
            margin: const EdgeInsets.only(right: 2),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
      ],
    );
  }
}

/// MCP Server settings section for the preferences page.
///
/// Contains the server enable toggle, port configuration, connection status,
/// Claude Desktop config snippet, and tool group toggles.
///
/// All settings are stored as a single JSON blob under [McpConfig.kPrefKey].
class McpServerSection extends ConsumerStatefulWidget {
  const McpServerSection({super.key});

  @override
  ConsumerState<McpServerSection> createState() => _McpServerSectionState();
}

class _McpServerSectionState extends ConsumerState<McpServerSection> {
  late TextEditingController _portController;
  bool _loaded = false;
  McpConfig _config = McpConfig.defaults;

  @override
  void initState() {
    super.initState();
    _portController =
        TextEditingController(text: McpConfig.defaultPort.toString());
  }

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  Future<void> _loadState() async {
    if (_loaded) return;
    // mcpConfigProvider reads device-local preferences and runs the
    // one-time migration off the shared database first.
    _config = await ref.read(mcpConfigProvider.future);
    _portController.text = _config.port.toString();
    _loaded = true;
  }

  /// Saves the current [_config] to device-local preferences and
  /// invalidates providers.
  Future<void> _saveConfig() async {
    await writeMcpConfigToPreferences(
        ref.read(localPreferencesProvider), _config);
    ref.invalidate(mcpConfigProvider);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      // Schedule initial load; will call setState when done.
      _loadState().then((_) {
        if (mounted) setState(() {});
      });
      return const SizedBox.shrink();
    }

    final bridge = ref.watch(mcpBridgeProvider);
    final bridgeState = bridge.currentState;
    final isRunning =
        bridgeState.connectionState == McpConnectionState.connected;
    final isStarting =
        bridgeState.connectionState == McpConnectionState.connecting;

    return Card(
      child: ExpansionTile(
        leading: const FaIcon(FontAwesomeIcons.robot, size: 20),
        title: const Text('MCP Server'),
        subtitle: Text(
          isRunning
              ? (bridgeState.port != null
                  ? 'Running on port ${bridgeState.port}'
                  : 'Running (in-process)')
              : isStarting
                  ? 'Starting…'
                  : 'Stopped',
          style: TextStyle(
            color: isRunning
                ? Colors.green
                : isStarting
                    ? Colors.orange
                    : Colors.grey,
            fontWeight: FontWeight.w500,
          ),
        ),
        initiallyExpanded: false,
        children: [
          // Enable/Disable toggle
          SwitchListTile(
            title: const Text('Enable MCP Server'),
            subtitle: const Text(
                'Allow Claude Desktop to connect via Streamable HTTP'),
            value: _config.serverEnabled,
            onChanged: (value) async {
              setState(() => _config = _config.copyWith(serverEnabled: value));
              await _saveConfig();
            },
          ),

          // Chat bubble toggle (only when server enabled, and only when the
          // chat feature is compiled in — a flag-off build must not offer a
          // toggle for a feature that is not in the binary)
          if (kChatEnabled && _config.serverEnabled)
            SwitchListTile(
              title: const Text('Show Chat Bubble'),
              subtitle: const Text(
                  'Display AI copilot chat button on the main screen'),
              value: _config.chatEnabled,
              onChanged: (value) async {
                setState(() => _config = _config.copyWith(chatEnabled: value));
                await _saveConfig();
              },
            ),

          // Port field
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _portController,
              decoration: const InputDecoration(
                labelText: 'Server Port',
                prefixIcon: FaIcon(FontAwesomeIcons.hashtag, size: 16),
              ),
              keyboardType: TextInputType.number,
              onSubmitted: (v) async {
                final port = int.tryParse(v) ?? McpConfig.defaultPort;
                setState(() => _config = _config.copyWith(port: port));
                await _saveConfig();
              },
            ),
          ),

          // Status indicator
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isRunning
                    ? Colors.green.withValues(alpha: 0.1)
                    : bridgeState.connectionState == McpConnectionState.error
                        ? Colors.red.withValues(alpha: 0.1)
                        : Colors.grey.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isRunning
                      ? Colors.green
                      : bridgeState.connectionState == McpConnectionState.error
                          ? Colors.red
                          : Colors.grey,
                ),
              ),
              child: Row(
                children: [
                  FaIcon(
                    isRunning
                        ? FontAwesomeIcons.circleCheck
                        : bridgeState.connectionState ==
                                McpConnectionState.error
                            ? FontAwesomeIcons.circleExclamation
                            : FontAwesomeIcons.circle,
                    color: isRunning
                        ? Colors.green
                        : bridgeState.connectionState ==
                                McpConnectionState.error
                            ? Colors.red
                            : Colors.grey,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isRunning
                          ? (bridgeState.port != null
                              ? 'Server running on port ${bridgeState.port}'
                              : 'Server running (in-process)')
                          : bridgeState.connectionState ==
                                  McpConnectionState.error
                              ? 'Error: ${bridgeState.error}'
                              : isStarting
                                  ? 'Server starting…'
                                  : 'Server stopped',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Claude Desktop config snippet (only when running with SSE port)
          if (isRunning && bridgeState.port != null)
            _ClaudeDesktopConfigSnippet(port: bridgeState.port!),

          // Divider before tool toggles
          if (_config.serverEnabled) const Divider(),

          // Tool toggles (only visible when MCP enabled)
          if (_config.serverEnabled)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Tool Groups',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ),
          if (_config.serverEnabled)
            for (final meta in McpToolToggles.toolGroupMeta)
              SwitchListTile(
                title: Text(meta.title),
                subtitle: Text(meta.description),
                value: _config.toggles.getByKey(meta.key),
                onChanged: (value) async {
                  final newToggles =
                      _config.toggles.copyWithToggle(meta.key, value);
                  setState(
                      () => _config = _config.copyWith(toggles: newToggles));
                  await _saveConfig();
                  io.stderr.writeln(
                    'AUDIT: toggle_change key=${meta.key} '
                    'value=$value '
                    'timestamp=${DateTime.now().toIso8601String()}',
                  );
                },
              ),
        ],
      ),
    );
  }
}

/// Shows a copyable Claude Desktop config snippet.
class _ClaudeDesktopConfigSnippet extends StatelessWidget {
  final int port;
  const _ClaudeDesktopConfigSnippet({required this.port});

  @override
  Widget build(BuildContext context) {
    // Claude Desktop speaks Streamable HTTP directly -- the older
    // `npx mcp-remote` stdio bridge is not needed.
    final config = '''{
  "mcpServers": {
    "centroid-hmi": {
      "type": "http",
      "url": "http://127.0.0.1:$port/mcp"
    }
  }
}''';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Claude Desktop Config',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const Spacer(),
              IconButton(
                icon: const FaIcon(FontAwesomeIcons.copy, size: 14),
                tooltip: 'Copy to clipboard',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: config));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Config copied to clipboard'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
            ],
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: SelectableText(
              config,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class DatabaseConfigWidget extends ConsumerStatefulWidget {
  const DatabaseConfigWidget({super.key});

  @override
  ConsumerState<DatabaseConfigWidget> createState() =>
      _DatabaseConfigWidgetState();
}

class _DatabaseConfigWidgetState extends ConsumerState<DatabaseConfigWidget> {
  DatabaseConfig? _config;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final config = await DatabaseConfig.fromPrefs();
    if (mounted) {
      setState(() {
        _config = config;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // **The same card in both transports, editable in both.** The owner's
    // ruling, at the rig: "i dont see a reason why we cannot change or see
    // database config". These are this station's OWN settings — read from and
    // written to device-local secure storage by `DatabaseConfig.fromPrefs` /
    // `toPrefs`, never over the relay — and they are what the station runs on
    // the moment somebody switches the transport back to Direct. A panel that
    // could not show or edit them was stranded at exactly that moment.
    //
    // What the transport still decides is what this card may CLAIM. In
    // gateway mode nothing dials: `databaseProvider` returns null before it
    // reads the row, and `preferencesProvider` carries the same branch one
    // level up so nothing pulls the pool in by watching. So there is no
    // connection state to report and no pool to census, and the editor's
    // `dialling` flag is false. A status line must be true or absent: rendering "Disconnected"
    // in red would read as a fault on a healthy panel, and rendering
    // "Connected" was the lie that branch exists to remove.
    final gatewayAsync = ref.watch(gatewayConfigProvider);
    if (gatewayAsync.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final gateway = gatewayAsync.valueOrNull ?? GatewayConfig.defaults;
    if (_loading || _config == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return _DatabaseConfigEditor(
      config: _config!,
      dialling: !gateway.isGateway,
      onSave: (newConfig) async {
        await newConfig.toPrefs();
        // Safe in both transports: in gateway mode this provider answers null
        // on its own transport branch without opening anything, and nothing
        // in gateway mode watches it — the invalidate is a no-op there rather
        // than a dial.
        ref.invalidate(databaseProvider);
        // Reload config after save so the editor reflects new values
        _loadConfig();
      },
    );
  }
}

class _DatabaseConfigEditor extends ConsumerStatefulWidget {
  final DatabaseConfig config;
  final ValueChanged<DatabaseConfig> onSave;

  /// Whether this station is the one dialling these settings — true in
  /// direct mode, false in gateway mode, where the backend owns the database
  /// and this panel opens no pool of its own.
  ///
  /// It gates what the card SAYS, never what it lets an operator change: the
  /// row is device-local and applies whenever the transport is Direct, so it
  /// stays editable either way. False means no connection-state stream is
  /// subscribed (there is none to describe), no census button (the census
  /// reads a pool this station does not hold), and a neutral statement in
  /// place of a green/red claim.
  final bool dialling;

  const _DatabaseConfigEditor({
    required this.config,
    required this.onSave,
    this.dialling = true,
  });

  @override
  ConsumerState<_DatabaseConfigEditor> createState() =>
      _DatabaseConfigEditorState();
}

class _DatabaseConfigEditorState extends ConsumerState<_DatabaseConfigEditor> {
  late TextEditingController hostController;
  late TextEditingController portController;
  late TextEditingController dbController;
  late TextEditingController userController;
  late TextEditingController passController;
  late bool isUnixSocket;
  late SslMode? sslMode;

  @override
  void initState() {
    super.initState();
    final endpoint = widget.config.postgres;
    hostController = TextEditingController(text: endpoint?.host ?? '');
    portController = TextEditingController(
      text: endpoint?.port.toString() ?? '5432',
    );
    dbController = TextEditingController(text: endpoint?.database ?? '');
    userController = TextEditingController(text: endpoint?.username ?? '');
    passController = TextEditingController(text: endpoint?.password ?? '');
    isUnixSocket = endpoint?.isUnixSocket ?? false;
    sslMode = widget.config.sslMode;
  }

  @override
  Widget build(BuildContext context) {
    // Use AsyncValue directly instead of FutureBuilder to avoid
    // Future identity changes that destroy ExpansionTile state on rebuild.
    //
    // **Watched only where it is needed**, which is the transport that
    // dials: the shared store is this card's source for ONE thing, the
    // connection stream in the two `StreamBuilder`s below. Everything else
    // it renders comes from `widget.config` and goes back out through
    // `widget.onSave` to device-local secure storage. And `preferencesProvider`
    // is not a cheap read — it builds the guarded store, the access policy and
    // the audit sink, and those reach `databaseProvider` — so watching it from
    // a gateway panel would drag the whole chain up to render a card that
    // needs none of it. `preferences_database_section_test.dart` asserts the
    // provider is never touched in gateway mode, and that arm is what noticed.
    final AsyncValue<Preferences?> prefsAsync = widget.dialling
        ? ref.watch(preferencesProvider)
        : const AsyncValue<Preferences?>.data(null);
    // The neutral voice for everything this card says when it is not the one
    // dialling. `onSurface` with alpha, never `colorScheme.outline`: neither
    // Solarized scheme sets that and it disappears on dark.
    final muted =
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65);

    return prefsAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16.0),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => Padding(
        padding: const EdgeInsets.all(16.0),
        child: Center(child: Text('Error: $error')),
      ),
      data: (prefs) => Card(
        child: ExpansionTile(
          leading: const FaIcon(FontAwesomeIcons.database, size: 20),
          title: Row(
            children: [
              const Text('Database Configuration'),
              // Reaching the connection census through psql is exactly what
              // stops working when the server runs out of connections, so the
              // way in has to be here, in an app that already holds one — and
              // only where one is held. In gateway mode the census would
              // report on a pool this station does not have.
              if (widget.dialling)
                IconButton(
                  icon: const Icon(Icons.info_outline, size: 18),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Connection statistics',
                  onPressed: () => showDatabaseStatsPane(context),
                ),
            ],
          ),
          subtitle: widget.dialling
              ? StreamBuilder<bool>(
                  stream: prefs?.database?.connectionState,
                  initialData: false,
                  builder: (context, connectionSnapshot) {
                    final isConnected = connectionSnapshot.data ?? false;
                    return Text(
                      'Status: ${isConnected ? "Connected" : "Disconnected"}',
                      style: TextStyle(
                        color: isConnected ? Colors.green : Colors.red,
                        fontWeight: FontWeight.w500,
                      ),
                    );
                  },
                )
              // Not a status, because there is nothing to have a status: this
              // station dials nothing in gateway mode. It says what the
              // settings ARE for instead, which is the one thing an operator
              // standing here needs to know before changing them.
              : Text(
                  'Not dialled in gateway mode — the backend owns the '
                  'database. These settings apply when the transport is '
                  'Direct.',
                  style: TextStyle(color: muted),
                ),
          initiallyExpanded: false, // Default to folded
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!widget.dialling)
                    // The same fact as the subtitle, in the place the green
                    // or red box would be, so the operator who opened the
                    // card is not left looking for a status that is missing.
                    // Muted `onSurface`, never `colorScheme.outline`: neither
                    // Solarized scheme sets it and it vanishes on dark
                    // (project memory solarized-outline-is-invisible).
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: muted),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline, size: 16, color: muted),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              // One line, because the subtitle two rows
                              // above already says when these settings
                              // apply and this is only here to occupy —
                              // honestly — the place the green or red box
                              // takes in the transport that dials.
                              'No connection from this station — nothing '
                              'here is dialling.',
                              style: TextStyle(fontSize: 12, color: muted),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (widget.dialling)
                    StreamBuilder<bool>(
                      stream: prefs?.database?.connectionState,
                      initialData: false,
                      builder: (context, snapshot) {
                        return Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: (snapshot.data ?? false)
                                ? Colors.green.withOpacity(0.1)
                                : Colors.red.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: (snapshot.data ?? false)
                                  ? Colors.green
                                  : Colors.red,
                            ),
                          ),
                          child: Row(
                            children: [
                              FaIcon(
                                (snapshot.data ?? false)
                                    ? FontAwesomeIcons.checkCircle
                                    : FontAwesomeIcons.exclamationCircle,
                                color: (snapshot.data ?? false)
                                    ? Colors.green
                                    : Colors.red,
                                size: 16,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Connection Status: ${snapshot.data ?? false ? "Connected" : "Disconnected"}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: hostController,
                    decoration: const InputDecoration(
                      labelText: 'Host',
                      prefixIcon: FaIcon(FontAwesomeIcons.server, size: 16),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: portController,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      prefixIcon: FaIcon(FontAwesomeIcons.hashtag, size: 16),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: dbController,
                    decoration: const InputDecoration(
                      labelText: 'Database',
                      prefixIcon: FaIcon(FontAwesomeIcons.database, size: 16),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: userController,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      prefixIcon: FaIcon(FontAwesomeIcons.user, size: 16),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: passController,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      prefixIcon: FaIcon(FontAwesomeIcons.lock, size: 16),
                    ),
                    obscureText: true,
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    title: const Text('Is Unix Socket'),
                    value: isUnixSocket,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (v) => setState(() => isUnixSocket = v ?? false),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('SSL Mode: '),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: sslMode == null ? Colors.red : Colors.grey,
                              width: 1.0,
                            ),
                            borderRadius: BorderRadius.circular(4),
                            color: sslMode == null
                                ? Colors.red.withAlpha((0.05 * 255).toInt())
                                : null,
                          ),
                          child: DropdownButton<SslMode>(
                            value: sslMode,
                            isExpanded: true,
                            hint: const Text("Select SSL Mode"),
                            icon: const Icon(Icons.arrow_drop_down),
                            onChanged: (v) => setState(() => sslMode = v),
                            items: SslMode.values
                                .map(
                                  (e) => DropdownMenuItem(
                                    value: e,
                                    child: Text(e.name),
                                  ),
                                )
                                .toList(),
                            underline: const SizedBox(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        final newConfig = DatabaseConfig(
                          postgres: Endpoint(
                            host: hostController.text,
                            port: int.tryParse(portController.text) ?? 5432,
                            database: dbController.text,
                            username: userController.text,
                            password: passController.text,
                            isUnixSocket: isUnixSocket,
                          ),
                          sslMode: sslMode,
                        );
                        widget.onSave(newConfig);
                      },
                      icon: const FaIcon(FontAwesomeIcons.save, size: 16),
                      label: const Text('Save Database Config'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PreferencesKeysWidget extends ConsumerStatefulWidget {
  const PreferencesKeysWidget({Key? key}) : super(key: key);

  @override
  ConsumerState<PreferencesKeysWidget> createState() =>
      _PreferencesKeysWidgetState();
}

class _PreferencesKeysWidgetState extends ConsumerState<PreferencesKeysWidget>
    with AutomaticKeepAliveClientMixin {
  Map<String, Object?>? _allPrefs;
  Map<String, bool>? _dbKeyFlags;
  Preferences? _preferences;
  PreferencesApi? _localPrefs;
  bool _loading = true;

  // Unsaved editor contents and which row is open, held here rather than in
  // the row itself. Both lists below are lazy — the page-level ListView and
  // the key list — so a row is unmounted (and its State disposed) as soon as
  // it scrolls past the cache extent, and re-attaching the section rebuilds
  // every row from scratch. Anything the user has typed must therefore live
  // above both lists to survive.
  final Map<String, String> _drafts = {};

  // A set, not a single key: rows expand independently, so collapsing one on
  // remount because another was opened would be a regression.
  final Set<String> _expandedKeys = {};

  // Keeps this section itself mounted when the page scrolls past it, which is
  // what makes _drafts a safe place to keep that state (and avoids reloading
  // every preference value on the way back).
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // Defer loading until the first build, when the provider is available.
  }

  Future<void> _loadData(Preferences preferences) async {
    final localPrefs = ref.read(localPreferencesProvider);
    final results = await Future.wait([
      preferences.getAll(),
      localPrefs.getAll(),
    ]);
    final merged = <String, Object?>{};
    merged.addAll(results[1]); // local prefs first
    merged.addAll(results[0]); // db prefs override

    // Pre-fetch all isKeyInDatabase flags in parallel
    final dbFlags = <String, bool>{};
    await Future.wait(
      merged.keys.map((key) async {
        try {
          dbFlags[key] = await preferences
              .isKeyInDatabase(key)
              .timeout(const Duration(seconds: 2));
        } catch (_) {
          dbFlags[key] = false;
        }
      }),
    );

    if (mounted) {
      setState(() {
        _preferences = preferences;
        _localPrefs = localPrefs;
        _allPrefs = merged;
        _dbKeyFlags = dbFlags;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    final prefsAsync = ref.watch(preferencesProvider);

    return prefsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(child: Text('Error: $error')),
      data: (preferences) {
        // Trigger load once when preferences become available
        if (_loading && _preferences == null) {
          _loadData(preferences);
          return const Center(child: CircularProgressIndicator());
        }
        if (_loading) {
          return const Center(child: CircularProgressIndicator());
        }

        final allPrefs = _allPrefs!;
        final dbFlags = _dbKeyFlags!;
        final prefs = _preferences!;
        final localPrefs = _localPrefs!;

        if (allPrefs.isEmpty) {
          return const ListTile(title: Text('No preferences found.'));
        }

        final sortedEntries = allPrefs.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const FaIcon(FontAwesomeIcons.key, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Preferences Keys',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Expanded(
                  // .builder, not ListView(children:): the latter constructs
                  // every row up front, so a row re-mounted after scrolling
                  // would reuse a widget still holding the draft/expansion
                  // captured at the parent's last build — i.e. before the user
                  // typed anything. Building per row reads current state.
                  child: ListView.builder(
                    itemCount: sortedEntries.length,
                    itemBuilder: (context, index) {
                      final e = sortedEntries[index];
                      return _PreferenceKeyTile(
                        // Identity must follow the preference key, not the
                        // list position: adding or deleting a key reorders
                        // the list, and without this a kept-alive tile
                        // would rebind to a different preference.
                        key: ValueKey(e.key),
                        keyName: e.key,
                        value: e.value,
                        isInDatabase: dbFlags[e.key] ?? false,
                        initiallyExpanded: _expandedKeys.contains(e.key),
                        draft: _drafts[e.key],
                        // No setState: the row already holds this text in
                        // its own controller, and rebuilding the list on
                        // every keystroke would fight the editor.
                        onDraftChanged: (text) {
                          if (text == null) {
                            _drafts.remove(e.key);
                          } else {
                            _drafts[e.key] = text;
                          }
                        },
                        onExpansionChanged: (expanded) {
                          if (expanded) {
                            _expandedKeys.add(e.key);
                          } else {
                            _expandedKeys.remove(e.key);
                          }
                        },
                        onChanged: (newValue) async {
                          final isInDb = dbFlags[e.key] ?? false;
                          final target = isInDb ? prefs : localPrefs;

                          if (newValue is bool) {
                            await target.setBool(e.key, newValue);
                          } else if (newValue is int) {
                            await target.setInt(e.key, newValue);
                          } else if (newValue is double) {
                            await target.setDouble(e.key, newValue);
                          } else if (newValue is List<String>) {
                            await target.setStringList(e.key, newValue);
                          } else if (newValue is String) {
                            await target.setString(e.key, newValue);
                          }
                          // Reload data to reflect changes
                          _loading = true;
                          _loadData(prefs);
                        },
                        onDelete: () async {
                          // `autofocusConfirm` keeps the behaviour from #127:
                          // Enter confirms straight away when clearing out
                          // several keys in a row. Escape still dismisses
                          // without deleting.
                          final confirmed = await showConfirmDialog(
                            context: context,
                            title: 'Delete preference',
                            message: 'Delete "${e.key}"?',
                            confirmLabel: 'Delete',
                            destructive: true,
                            autofocusConfirm: true,
                          );
                          if (confirmed) {
                            final isInDb = dbFlags[e.key] ?? false;
                            if (isInDb) {
                              await prefs.remove(e.key);
                            } else {
                              await localPrefs.remove(e.key);
                            }
                            _drafts.remove(e.key);
                            _expandedKeys.remove(e.key);
                            // Reload data and invalidate provider
                            _loading = true;
                            _loadData(prefs);
                            ref.invalidate(preferencesProvider);
                          }
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PreferenceKeyTile extends StatefulWidget {
  final String keyName;
  final Object? value;
  final bool isInDatabase;
  final ValueChanged<Object?> onChanged;
  final VoidCallback onDelete;

  /// Expansion and in-progress edits are owned by the parent so they outlive
  /// this tile being unmounted by the surrounding lazy lists.
  final bool initiallyExpanded;
  final String? draft;
  final ValueChanged<String?> onDraftChanged;
  final ValueChanged<bool> onExpansionChanged;

  const _PreferenceKeyTile({
    super.key,
    required this.keyName,
    required this.value,
    required this.isInDatabase,
    required this.onChanged,
    required this.onDelete,
    required this.initiallyExpanded,
    required this.draft,
    required this.onDraftChanged,
    required this.onExpansionChanged,
  });

  @override
  State<_PreferenceKeyTile> createState() => _PreferenceKeyTileState();
}

class _PreferenceKeyTileState extends State<_PreferenceKeyTile> {
  late TextEditingController _controller;
  final _expansionController =
      ExpansionTileController(); // todo deprecated since 3.31
  late bool _isExpanded;

  String get _valueAsText => widget.value is String
      ? widget.value as String
      : widget.value?.toString() ?? '';

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded;
    // Seed from the parent-held draft so an edit that outlived this State
    // (see PreferencesKeysWidget) is restored rather than reverted.
    _controller = TextEditingController(text: widget.draft ?? _valueAsText);
    _controller.addListener(_reportDraft);
  }

  void _reportDraft() {
    widget.onDraftChanged(
      _controller.text == _valueAsText ? null : _controller.text,
    );
  }

  @override
  void dispose() {
    _controller.removeListener(_reportDraft);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _PreferenceKeyTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      // A new persisted value supersedes any draft, so adopt it without
      // reporting the change back up as an unsaved edit.
      _controller.removeListener(_reportDraft);
      _controller.text = _valueAsText;
      _controller.addListener(_reportDraft);
      widget.onDraftChanged(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    return ExpansionTile(
      controller: _expansionController,
      initiallyExpanded: widget.initiallyExpanded,
      leading: FaIcon(
        widget.isInDatabase
            ? FontAwesomeIcons.database
            : FontAwesomeIcons.hardDrive,
        size: 16,
        color: widget.isInDatabase ? Colors.blue : Colors.grey,
      ),
      title: Text(
        '(${widget.isInDatabase ? 'DB' : 'Local'}) ${widget.keyName}',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const FaIcon(FontAwesomeIcons.trash, size: 16),
            onPressed: widget.onDelete,
          ),
          IconButton(
            icon: FaIcon(
              _isExpanded
                  ? FontAwesomeIcons.chevronUp
                  : FontAwesomeIcons.chevronDown,
              size: 16,
            ),
            onPressed: () {
              if (_isExpanded) {
                _expansionController.collapse();
              } else {
                _expansionController.expand();
              }
            },
          ),
        ],
      ),
      onExpansionChanged: (expanded) {
        setState(() {
          _isExpanded = expanded;
        });
        widget.onExpansionChanged(expanded);
      },
      children: [
        if (value is bool)
          SwitchListTile(
            title: Text(widget.keyName),
            value: value,
            onChanged: (v) => widget.onChanged(v),
          )
        else if (value is int)
          ListTile(
            title: Text(widget.keyName),
            subtitle: TextField(
              controller: _controller,
              keyboardType: TextInputType.number,
              onSubmitted: (v) {
                final intVal = int.tryParse(v) ?? value;
                widget.onChanged(intVal);
              },
            ),
          )
        else if (value is double)
          ListTile(
            title: Text(widget.keyName),
            subtitle: TextField(
              controller: _controller,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onSubmitted: (v) {
                final doubleVal = double.tryParse(v) ?? value;
                widget.onChanged(doubleVal);
              },
            ),
          )
        else if (value is List<String>)
          ListTile(
            title: Text(widget.keyName),
            subtitle: TextField(
              controller: _controller,
              decoration: const InputDecoration(hintText: 'Comma separated'),
              onSubmitted: (v) {
                final listVal = v.split(',').map((e) => e.trim()).toList();
                widget.onChanged(listVal);
              },
            ),
          )
        else if (value is String)
          _buildStringEditor()
        else
          ListTile(
            title: Text(widget.keyName),
            subtitle: Text('Unsupported type: ${value.runtimeType}'),
          ),
      ],
    );
  }

  Widget _buildStringEditor() {
    // Try to decode as JSON
    dynamic decoded;
    bool isJson = false;
    try {
      decoded = jsonDecode(widget.value as String);
      isJson = true;
    } catch (_) {}

    if (isJson) {
      return _JsonEditor(
        keyName: widget.keyName,
        initialText: const JsonEncoder.withIndent('  ').convert(decoded),
        draft: widget.draft,
        onDraftChanged: widget.onDraftChanged,
        onSave: (formatted) {
          widget.onDraftChanged(null);
          widget.onChanged(formatted);
        },
      );
    } else {
      return ListTile(
        title: Text(widget.keyName),
        subtitle: TextField(
          controller: _controller,
          onSubmitted: (v) => widget.onChanged(v),
        ),
      );
    }
  }
}

/// IDE-like JSON editor with line numbers and format button
class _JsonEditor extends StatefulWidget {
  final String keyName;
  final String initialText;
  final ValueChanged<String> onSave;

  /// In-progress edit owned by the parent, so it survives this editor being
  /// unmounted when the surrounding lazy lists scroll it out of view.
  final String? draft;
  final ValueChanged<String?> onDraftChanged;

  const _JsonEditor({
    required this.keyName,
    required this.initialText,
    required this.draft,
    required this.onDraftChanged,
    required this.onSave,
  });

  @override
  State<_JsonEditor> createState() => _JsonEditorState();
}

class _JsonEditorState extends State<_JsonEditor> {
  late TextEditingController _controller;
  String? _error;
  static const double _lineHeight = 24.0;

  @override
  void initState() {
    super.initState();
    _controller =
        TextEditingController(text: widget.draft ?? widget.initialText);
    _controller.addListener(_reportDraft);
  }

  void _reportDraft() {
    widget.onDraftChanged(
      _controller.text == widget.initialText ? null : _controller.text,
    );
  }

  @override
  void dispose() {
    _controller.removeListener(_reportDraft);
    _controller.dispose();
    super.dispose();
  }

  void _formatJson() {
    try {
      final decoded = jsonDecode(_controller.text);
      final formatted = const JsonEncoder.withIndent('  ').convert(decoded);
      setState(() {
        _controller.text = formatted;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _error = 'Invalid JSON: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = '\n'.allMatches(_controller.text).length + 1;
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                widget.keyName,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              ElevatedButton(
                onPressed: _formatJson,
                child: const Text('Format JSON'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () {
                  try {
                    jsonDecode(_controller.text);
                    widget.onSave(_controller.text);
                    setState(() => _error = null);
                  } catch (e) {
                    setState(() => _error = 'Invalid JSON: $e');
                  }
                },
                child: const Text('Save'),
              ),
            ],
          ),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey),
              color: Colors.black.withOpacity(0.05),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Line numbers
                Container(
                  color: Colors.grey[200],
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: List.generate(
                      lines,
                      (i) => SizedBox(
                        height: _lineHeight,
                        child: Text(
                          '${i + 1}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // JSON editor
                Expanded(
                  child: TextField(
                    controller: _controller,
                    maxLines: null,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                      height: _lineHeight / 14,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
        ],
      ),
    );
  }
}
