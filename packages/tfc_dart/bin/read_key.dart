/// Reads a logical key straight off OPC UA, bypassing StateMan's subscription
/// cache, the MCP tag cache and the HMI widgets.
///
/// Use it to settle "the HMI says X, is that really what the PLC holds?" --
/// a fresh session and a fresh read every invocation, so a stale subscription
/// cannot colour the answer.
///
///   dart run bin/read_key.dart SPB03.CN03.FD01
///   dart run bin/read_key.dart --field p_stat_RunMode SPB03.CN03.FD01
///   dart run bin/read_key.dart --node 'ns=4;s=ECT.SPB03_CN03_FD01.HMI' --alias st301
///
/// Connection details and key mappings come from the HMI's own preferences
/// file, so the CLI talks to exactly the servers the HMI talks to. Override
/// with --prefs, or supply --endpoint/--username/--password directly.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:open62541/open62541.dart';
import 'package:tfc_dart/core/log_config.dart' show opcuaLogLevelFromEnv;
import 'package:tfc_dart/core/state_man_types.dart';

/// Default location of the HMI preferences file per platform.
String? _defaultPrefsPath() {
  final env = Platform.environment;
  if (Platform.isWindows) {
    final appData = env['APPDATA'];
    if (appData == null) return null;
    return '$appData\\centroidx\\shared_preferences.json';
  }
  final home = env['HOME'];
  if (home == null) return null;
  if (Platform.isMacOS) {
    return '$home/Library/Containers/is.centroid.centroidx/Data/Documents/shared_preferences.json';
  }
  return '$home/.local/share/centroidx/shared_preferences.json';
}

/// Pulls a JSON blob out of the preferences file, tolerating the `flutter.`
/// prefix that SharedPreferences adds on some platforms.
Map<String, dynamic>? _prefEntry(Map<String, dynamic> prefs, String key) {
  final raw = prefs[key] ?? prefs['flutter.$key'];
  if (raw == null) return null;
  return jsonDecode(raw is String ? raw : jsonEncode(raw))
      as Map<String, dynamic>;
}

Future<int> run(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('prefs',
        help: 'HMI preferences JSON (defaults to the platform location)')
    ..addOption('node',
        help: "Read this node directly, e.g. 'ns=4;s=ECT.X.HMI'. "
            'Skips key-mapping lookup; requires --alias or --endpoint.')
    ..addOption('alias', help: 'Server alias to connect to (e.g. st301)')
    ..addOption('endpoint', help: 'Override the endpoint URL')
    ..addOption('username', help: 'Override the username')
    ..addOption('password', help: 'Override the password')
    ..addOption('field',
        help: 'Print only this field of a struct (e.g. p_stat_RunMode)')
    ..addOption('timeout',
        help: 'Seconds to wait for connect and for read', defaultsTo: '20')
    ..addFlag('json', negatable: false, help: 'Emit JSON instead of text')
    ..addFlag('help', abbr: 'h', negatable: false);

  final args = parser.parse(argv);
  if (args['help'] as bool || (args.rest.isEmpty && args['node'] == null)) {
    stdout.writeln('Read a logical key or node straight off OPC UA.\n');
    stdout.writeln('Usage: dart run bin/read_key.dart [options] <key>\n');
    stdout.writeln(parser.usage);
    return args['help'] as bool ? 0 : 2;
  }

  final timeout =
      Duration(seconds: int.tryParse(args['timeout'] as String) ?? 20);

  final prefsPath = args['prefs'] as String? ?? _defaultPrefsPath();
  Map<String, dynamic> prefs = {};
  if (prefsPath != null && File(prefsPath).existsSync()) {
    prefs =
        jsonDecode(File(prefsPath).readAsStringSync()) as Map<String, dynamic>;
  } else if (args['endpoint'] == null) {
    stderr.writeln('No preferences file at $prefsPath, and no --endpoint '
        'given. Nothing to connect to.');
    return 2;
  }

  // Resolve the node: either given outright, or looked up in key mappings.
  NodeId nodeId;
  String? alias = args['alias'] as String?;
  String label;

  final nodeArg = args['node'] as String?;
  if (nodeArg != null) {
    final match = RegExp(r'^ns=(\d+);s=(.+)$').firstMatch(nodeArg.trim());
    if (match == null) {
      stderr.writeln("Could not parse --node '$nodeArg'. "
          "Expected the form 'ns=<int>;s=<identifier>'.");
      return 2;
    }
    nodeId = NodeId.fromString(int.parse(match.group(1)!), match.group(2)!);
    label = nodeArg;
  } else {
    final key = args.rest.first;
    final mappingJson = _prefEntry(prefs, 'key_mappings');
    if (mappingJson == null) {
      stderr.writeln('No key_mappings in $prefsPath; pass --node instead.');
      return 2;
    }
    final entry = KeyMappings.fromJson(mappingJson).nodes[key];
    if (entry == null) {
      stderr.writeln('Key not found in mappings: $key');
      return 1;
    }
    final node = entry.opcuaNode;
    if (node == null) {
      stderr.writeln('Key "$key" is not an OPC UA key.');
      return 1;
    }
    nodeId = NodeId.fromString(node.namespace, node.identifier);
    alias ??= node.serverAlias;
    label = '$key (ns=${node.namespace};s=${node.identifier})';
  }

  // Resolve the server.
  OpcUAConfig? server;
  final configJson = _prefEntry(prefs, StateManConfig.configKey);
  if (configJson != null) {
    final config = StateManConfig.fromJson(configJson);
    for (final candidate in config.opcua) {
      if (StateManConfig.normalizeAlias(candidate.serverAlias) ==
          StateManConfig.normalizeAlias(alias)) {
        server = candidate;
        break;
      }
    }
    if (server == null && alias != null) {
      stderr.writeln('No OPC UA server configured with alias "$alias". '
          'Configured: ${config.opcua.map((c) => c.serverAlias).join(', ')}');
      return 1;
    }
    server ??= config.opcua.isNotEmpty ? config.opcua.first : null;
  }

  final endpoint = args['endpoint'] as String? ?? server?.endpoint;
  if (endpoint == null) {
    stderr.writeln('No endpoint resolved. Pass --endpoint.');
    return 2;
  }
  final username = args['username'] as String? ?? server?.username;
  final password = args['password'] as String? ?? server?.password;

  final cert = server?.sslCert;
  final key = server?.sslKey;
  final securityMode = (cert != null && key != null)
      ? MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT
      : MessageSecurityMode.UA_MESSAGESECURITYMODE_NONE;

  stderr.writeln('Connecting to $endpoint '
      '(alias ${alias ?? '<none>'}, security ${securityMode.name})...');

  // Connect through ClientIsolate, the same path StateMan uses
  // (state_man.dart:1193-1203). A bare Client needs its state machine pumped
  // by hand via runIterate, and on an encrypted endpoint it loops
  // FindServers -> GetEndpoints without ever settling; the isolate runs that
  // loop itself and completes the handshake.
  final client = await ClientIsolate.create(
    username: username,
    password: password,
    certificate: cert,
    privateKey: key,
    securityMode: securityMode,
    logLevel: opcuaLogLevelFromEnv(),
    secureChannelLifeTime: const Duration(minutes: 1),
  );

  // The isolate still needs its event loop driven from outside: StateMan runs
  // exactly this loop against the wrapper (state_man.dart:1019-1027). Without
  // it the handshake stalls after the TCP connect and every call times out.
  var pumping = true;
  Future<void> pump() async {
    while (pumping) {
      try {
        await client.runIterate(duration: const Duration(milliseconds: 10));
      } catch (_) {
        // A replaced iterate, or a closed isolate, is not fatal here; the
        // awaited connect/read carries the real error.
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  unawaited(pump());

  try {
    await client.connect(endpoint).timeout(timeout,
        onTimeout: () => throw TimeoutException(
            'Timed out connecting to $endpoint', timeout));
    final value = await client.read(nodeId).timeout(timeout,
        onTimeout: () =>
            throw TimeoutException('Timed out reading $label', timeout));

    final field = args['field'] as String?;
    final selected = field == null ? value : value[field];

    if (args['json'] as bool) {
      stdout.writeln(jsonEncode({
        'node': label,
        'endpoint': endpoint,
        'alias': alias,
        'field': field,
        'value': selected.toString(),
        'readAt': DateTime.now().toUtc().toIso8601String(),
      }));
    } else {
      stdout.writeln('$label${field == null ? '' : '.$field'}');
      stdout.writeln('  read at ${DateTime.now().toUtc().toIso8601String()}');
      stdout.writeln('  $selected');
      // Spell out the enum options so a surprising name can be checked
      // against what the server actually defines.
      final fields = selected.enumFields;
      if (fields != null) {
        final options =
            fields.entries.map((e) => '${e.value.name}(${e.key})').join(', ');
        stdout.writeln('  enum options: $options');
      }
    }
    return 0;
  } catch (e) {
    stderr.writeln('Read failed: $e');
    return 1;
  } finally {
    pumping = false;
    await client.disconnect();
  }
}

Future<void> main(List<String> argv) async {
  exitCode = await run(argv);
}
