/// The MCP server settings card — the native arm of `mcp_server_section.dart`.
///
/// Lifted out of `widgets/preferences.dart` unchanged. It is here rather than
/// there because that file is imported by the Server Config page, which is a
/// web route, and this card names `tfc_mcp_server` and `providers/mcp_bridge`
/// — `mcp_dart` and `drift/native.dart`, neither of which dart2js can compile.
/// A Dart import is all-or-nothing, so one card in one library kept the whole
/// settings screen off the web.
library;

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
// The settings type only — see the note in `pages/server_config.dart`.
import 'package:tfc_dart/core/database_config.dart';

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
