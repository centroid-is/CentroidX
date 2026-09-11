/// Where the relay WebSocket is configured, and what happens when it is not.
///
/// ## Off is the default, and that is the deployment-safety property
///
/// Every plant backend at SVN will get this binary before anybody turns the
/// WebSocket on. If an upgrade changed what a station serves by default it
/// would change it on every station at once, at whatever hour the images roll.
/// So [RelayConfig.fromJson] answers **null** when the config file has no
/// `relay` section: null means the WebSocket is off, the backend boots exactly
/// as it does today, and [RelayBoot.bootLogLine] is the single line that says
/// so.
///
/// The other half of that rule is that a section which *is* present but broken
/// **throws**. Off-by-absence and broken-by-typo are different facts, and a
/// parser that turned a misspelled key into "off" is how a plant runs unserved
/// for a week behind a green log. Unknown keys inside the section are refused
/// for the same reason: `"prot": 8443` must not silently become an ephemeral
/// port.
///
/// ## Why the section lives inside the stateman file
///
/// The backend already loads one config file, named by
/// `CENTROID_STATEMAN_FILE_PATH` (`bin/main.dart:56-61`). A second file beside
/// it would be a second thing to mount, a second thing to template and a
/// second thing to forget — which is how two deployments of one process drift
/// apart. 13-CONTEXT states the rule as a refusal: **no code path reachable
/// from the backend entrypoint reads a `gateway.json`**, and
/// `test/core/relay/no_gateway_json_test.dart` pins it.
///
/// `StateManConfig` is deliberately **not** extended to carry this. That class
/// is `json_serializable`-generated (`state_man.dart:511`), so a field on it
/// means a `build_runner` regeneration and a generated-file diff arriving in
/// the same commit as a config parser. The `relay` key is parsed out of the
/// same file's raw JSON instead, here, by hand.
///
/// ## One credential source
///
/// `RelayServer`'s constructor (`relay_server.dart:155`) throws an
/// `ArgumentError` when it is handed both a `ServerConfig.auth` and an explicit
/// `validator`, because "two sources of truth for the credential check is a
/// configuration nobody can reason about, and the one that wins would be an
/// implementation detail". Two independent config fields that could both be
/// set would push that throw out to boot time on a plant machine. So the
/// config carries a **single** [RelayCredentials] value chosen by
/// `credentials.source`, and the forbidden pair is refused here, at parse
/// time, with the constructor's own reasoning quoted.
///
/// ## The wire shape
///
/// ```json
/// {
///   "opcua": [ … ],
///   "relay": {
///     "port": 8443,
///     "address": "0.0.0.0",
///     "publisher_id": "centroidx-backend-svn",
///     "allowed_origins": ["https://hmi.svn.local"],
///     "tls": {
///       "chain_path": "/etc/relay/chain.pem",
///       "key_path": "/etc/relay/key.pem",
///       "key_password": "…"
///     },
///     "credentials": {
///       "source": "token_file",
///       "token_file": "/run/secrets/relay-tokens.json"
///     }
///   }
/// }
/// ```
///
/// `port` and `credentials` are required when the section is present. `port`
/// because `ServerConfig`'s default is `0` — an ephemeral port, right for the
/// free-port draw a test does and wrong for a plant whose panels are
/// configured with a fixed address (08-REVIEW IN-03); `credentials` because
/// the alternative is an unauthenticated WebSocket on the plant LAN arriving
/// through a line somebody left out rather than through a line somebody wrote.
/// `{"source": "none"}` is how a deployment says it checks no credential, and
/// it is visible in a config diff.
///
/// ## What this file does NOT configure
///
/// Every `ServerConfig` field the section does not name keeps the default the
/// server package argued for, in that package, next to the measurement. In
/// particular the timeseries ceilings (`maxTimeseriesPoints` and 13-05's
/// `TimeseriesLimits.maxRows`) are **not** exposed here: each is arithmetic
/// derived from a panel width or a retention horizon, written out where it
/// lives, and a knob copied into a plant config file is a knob that drifts
/// from the reasoning that produced it. A deployment that genuinely needs one
/// adds the line in the commit that needs it. `toServerConfig` is scanned by
/// an arm that refuses any label outside the allow list, so the addition
/// cannot happen silently.
///
/// Restart-to-apply is likewise not here: a relay-config change takes the same
/// path as any other config change, through the backend's existing
/// `PreferencesWatcher` → `_shutdown()` (`bin/main.dart:31`), which is
/// kill-based and awaits nothing. Nothing in this file starts a watcher or a
/// timer.
library;

import 'dart:convert';
import 'dart:io';

import 'package:tfc_relay_server/tfc_relay_server.dart';

/// The environment variables that override the operational knobs.
///
/// Operational only: an address, a port, where the TLS material and the token
/// file are mounted. Nothing here can change *whether* there is a relay to
/// configure — [envEnabled] can only turn a configured relay off, never invent
/// one — because an env variable cannot supply a port, a credential source or
/// a certificate.
abstract final class RelayEnv {
  /// Where the backend's one config file is named.
  ///
  /// **Not a relay knob** — it is `bin/main.dart:56-57`'s existing variable,
  /// declared here so the composition root and this parser share one spelling
  /// and so `no_gateway_json_test.dart`'s positive arm can see, in code rather
  /// than in prose, which file the `relay` section comes out of. There is no
  /// second config file: see the library doc.
  static const String statemanFilePath = 'CENTROID_STATEMAN_FILE_PATH';

  /// `0`/`false`/`no`/`off` forces the relay off even with a section present.
  static const String enabled = 'CENTROID_RELAY_ENABLED';
  static const String port = 'CENTROID_RELAY_PORT';
  static const String address = 'CENTROID_RELAY_ADDRESS';
  static const String tlsChain = 'CENTROID_RELAY_TLS_CHAIN';
  static const String tlsKey = 'CENTROID_RELAY_TLS_KEY';
  static const String tlsKeyPassword = 'CENTROID_RELAY_TLS_KEY_PASSWORD';
  static const String tokenFile = 'CENTROID_RELAY_TOKEN_FILE';

  /// Every name above, so a caller can log or scan the set.
  static const List<String> all = <String>[
    enabled,
    port,
    address,
    tlsChain,
    tlsKey,
    tlsKeyPassword,
    tokenFile,
  ];
}

/// How this deployment checks a credential. Exactly one of three.
///
/// A sealed hierarchy rather than two nullable fields, because two nullable
/// fields can both be set and this cannot. See the library doc.
sealed class RelayCredentials {
  const RelayCredentials();

  /// What the boot line says about this source. Never a secret — the token
  /// file is a path, and the thing in it is not read here.
  String get description;
}

/// This deployment checks no credential at all.
///
/// Said out loud, in the config file, because the alternative spelling of it
/// is a forgotten line.
final class RelayNoCredentialCheck extends RelayCredentials {
  const RelayNoCredentialCheck();

  @override
  String get description => 'none (no credential check)';
}

/// Credentials come from a token file, which becomes `ServerConfig.auth`.
final class RelayTokenFileCredentials extends RelayCredentials {
  const RelayTokenFileCredentials(this.tokenFilePath);

  final String tokenFilePath;

  @override
  String get description => 'token file $tokenFilePath';
}

/// The composition root supplies its own `TokenValidator`.
///
/// `ServerConfig.auth` stays null in this case, which is the whole point: the
/// pair `relay_server.dart:155` refuses is unconstructible from this config.
final class RelayValidatorCredentials extends RelayCredentials {
  const RelayValidatorCredentials();

  @override
  String get description => 'a validator supplied by the composition root';
}

/// Why the relay is off.
enum RelayOffReason {
  /// The config file has no `relay` section. The upgrade-safe default.
  noSection,

  /// A section is present and `CENTROID_RELAY_ENABLED` turned it off.
  disabledByEnv,
}

/// The outcome of reading the relay section: a config or a reason there is
/// none, and in both cases the one line the backend prints.
///
/// **Why this type exists.** The plan asked for `String get bootLogLine` with
/// an off shape and an on shape, and for the parse to answer `null` when the
/// relay is off. Those cannot both live on [RelayConfig]: when the relay is
/// off there is no instance to ask. Rather than have the caller reconstruct
/// the reason from the same env map the parser already read — where "absent
/// section" and "disabled by env" would be two conditions to get right at the
/// one call site nobody tests — the decision and its line are returned
/// together. [RelayConfig.fromJson] and [RelayConfig.fromStatemanFile] keep
/// the nullable signature and delegate here.
final class RelayBoot {
  const RelayBoot._(this.config, this.offReason, this.bootLogLine);

  /// The relay's configuration, or null when it is off.
  final RelayConfig? config;

  /// Why it is off, or null when it is on.
  final RelayOffReason? offReason;

  /// The one line the backend prints at boot. Never more than one line, and
  /// never a secret.
  final String bootLogLine;

  bool get isOn => config != null;

  /// Reads the `relay` key out of an already-decoded stateman file.
  ///
  /// [source] is only used in messages — it is the path an operator would
  /// open, and a refusal that does not name the file sends them grepping.
  factory RelayBoot.fromStatemanJson(
    Map<String, dynamic> statemanJson, {
    required String source,
    Map<String, String> env = const <String, String>{},
  }) {
    final raw = statemanJson['relay'];
    if (raw == null) {
      // Absent beats disabled-by-env in the reason given: there was nothing to
      // disable, and the truthful reason is the one an operator can act on.
      return RelayBoot._(
        null,
        RelayOffReason.noSection,
        'relay WebSocket is OFF: no `relay` section in $source. '
            'This backend serves no WebSocket; add a `relay` section to turn '
            'it on.',
      );
    }
    // Parsed before the enabled check so a broken section is loud even in a
    // deployment that has it switched off — otherwise the typo is discovered
    // on the day somebody flips the variable.
    final config = RelayConfig._parse(raw, source: source, env: env);
    if (!_envEnabled(env, source)) {
      return RelayBoot._(
        null,
        RelayOffReason.disabledByEnv,
        'relay WebSocket is OFF: disabled by ${RelayEnv.enabled}='
            '${env[RelayEnv.enabled]} (a `relay` section IS present in '
            '$source).',
      );
    }
    return RelayBoot._(config, null, config.bootLogLine);
  }

  /// Reads and decodes [path], then [RelayBoot.fromStatemanJson].
  ///
  /// This is the same file `StateManConfig.fromFile` reads
  /// (`state_man.dart:481`) — read twice rather than threaded through that
  /// generated class, which is the trade the library doc explains.
  static Future<RelayBoot> fromStatemanFile(
    String path, {
    Map<String, String> env = const <String, String>{},
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw ArgumentError('relay config: the stateman config file $path does '
          'not exist. A path that read as "relay off" would be a plant '
          'running unserved with nothing in the log about it, so this is a '
          'refusal rather than a default');
    }
    final Map<String, dynamic> json;
    try {
      json = (jsonDecode(await file.readAsString()) as Map)
          .cast<String, dynamic>();
    } on FormatException catch (e) {
      throw ArgumentError(
          'relay config: $path is not valid JSON — ${e.message}');
    }
    return RelayBoot.fromStatemanJson(json, source: path, env: env);
  }

  /// Whether the environment permits a configured relay to run.
  static bool _envEnabled(Map<String, String> env, String source) {
    final raw = env[RelayEnv.enabled];
    if (raw == null) return true;
    switch (raw.trim().toLowerCase()) {
      case '1':
      case 'true':
      case 'yes':
      case 'on':
        return true;
      case '0':
      case 'false':
      case 'no':
      case 'off':
        return false;
      default:
        throw ArgumentError('relay config: ${RelayEnv.enabled}="$raw" is '
            'neither on nor off. Accepted: 1/true/yes/on and 0/false/no/off. '
            'A value nobody parses would have to mean one of them, and '
            'guessing which is how a station comes up serving when it was '
            'meant to be quiet (config: $source)');
    }
  }
}

/// The relay WebSocket's configuration, as parsed from the backend's own
/// config world.
final class RelayConfig {
  const RelayConfig._({
    required this.source,
    required this.port,
    required this.credentials,
    required this.address,
    required this.tls,
    required this.allowedOrigins,
    required this.publisherId,
  });

  /// The file this came out of. Messages and the boot line name it.
  final String source;

  /// The TCP port to bind. Required in the file — see the library doc.
  final int port;

  /// The one credential source. Exactly one, by construction.
  final RelayCredentials credentials;

  /// The interface to bind, or null to keep `ServerConfig`'s loopback default.
  ///
  /// Null rather than a re-spelled `InternetAddress.loopbackIPv4`:
  /// `server_config.dart:272-278` argues that binding a plant interface is a
  /// decision with a firewall attached to it, and that argument belongs where
  /// it is written.
  final InternetAddress? address;

  /// The certificate pair, or null for plaintext. Never half of one — that is
  /// refused at parse time rather than at bind time.
  final TlsConfig? tls;

  /// Browser origins allowed to open a socket, or null to keep
  /// `ServerConfig`'s empty-list default. Never a null list on the way out:
  /// `server_config.dart:140-148` records that `null` there means
  /// cross-site WebSocket hijacking is permitted.
  final List<String>? allowedOrigins;

  /// What this backend calls itself on the wire, or null to say nothing.
  final String? publisherId;

  /// True when the composition root, not this config, supplies the validator.
  bool get suppliesOwnValidator => credentials is RelayValidatorCredentials;

  /// The relay section of an already-decoded stateman file, or **null** when
  /// there is none.
  ///
  /// Null is the WebSocket being off. It is not an error and it must never
  /// become one: see the library doc.
  static RelayConfig? fromJson(
    Map<String, dynamic> statemanJson, {
    Map<String, String> env = const <String, String>{},
    String source = 'stateman.json',
  }) =>
      RelayBoot.fromStatemanJson(statemanJson, source: source, env: env).config;

  /// The relay section of the file at [path], or null when there is none.
  static Future<RelayConfig?> fromStatemanFile(
    String path, {
    Map<String, String> env = const <String, String>{},
  }) async =>
      (await RelayBoot.fromStatemanFile(path, env: env)).config;

  /// `ServerConfig` with the fields this config names, and nothing else.
  ///
  /// Every other field keeps the server package's default. A number copied
  /// here is a number that drifts from the paragraph that justified it, and
  /// `relay_config_test.dart` scans this construction's labels to keep the
  /// list honest.
  ServerConfig toServerConfig() => ServerConfig(
        address: address,
        port: port,
        tls: tls,
        auth: switch (credentials) {
          RelayTokenFileCredentials(:final tokenFilePath) =>
            AuthConfig(tokenFilePath: tokenFilePath),
          RelayNoCredentialCheck() || RelayValidatorCredentials() => null,
        },
        allowedOrigins: allowedOrigins ?? const <String>[],
        publisherId: publisherId,
      );

  /// The one line the backend prints when the relay comes up.
  ///
  /// Built from [toServerConfig] rather than from the fields, so the line
  /// cannot report an address the server was not given.
  String get bootLogLine {
    final mapped = toServerConfig();
    final origins = mapped.allowedOrigins.length;
    return 'relay WebSocket is ON: ${mapped.address.address}:${mapped.port}, '
        'TLS ${mapped.tls == null ? 'no' : 'yes'}, '
        'credentials ${credentials.description}, '
        '$origins allowed origin${origins == 1 ? '' : 's'} '
        '(config: $source)';
  }

  // -------------------------------------------------------------------
  // Parsing. Every refusal names the field an operator would edit.

  static const Set<String> _knownKeys = <String>{
    'port',
    'address',
    'tls',
    'credentials',
    'allowed_origins',
    'publisher_id',
  };

  static const Set<String> _knownTlsKeys = <String>{
    'chain_path',
    'key_path',
    'key_password',
  };

  static const Set<String> _knownCredentialKeys = <String>{
    'source',
    'token_file',
  };

  static RelayConfig _parse(
    Object raw, {
    required String source,
    required Map<String, String> env,
  }) {
    if (raw is! Map) {
      throw ArgumentError('relay config: `relay` in $source is a '
          '${raw.runtimeType}, not an object. The section is a JSON object '
          'with at least `port` and `credentials`');
    }
    final json = raw.cast<String, dynamic>();
    _refuseUnknown(json.keys, _knownKeys, 'relay', source);

    final port = _port(json, source, env);
    final address = _address(json, source, env);
    final tls = _tls(json, source, env);
    final credentials = _credentials(json, source, env);
    final origins = _allowedOrigins(json, source);
    final publisherId = _optionalString(json, 'publisher_id', 'relay', source);

    return RelayConfig._(
      source: source,
      port: port,
      credentials: credentials,
      address: address,
      tls: tls,
      allowedOrigins: origins,
      publisherId: publisherId,
    );
  }

  static void _refuseUnknown(
    Iterable<String> present,
    Set<String> known,
    String path,
    String source,
  ) {
    final unknown = present.where((k) => !known.contains(k)).toList()..sort();
    if (unknown.isEmpty) return;
    throw ArgumentError('relay config: $path in $source names '
        '${unknown.map((k) => '`$k`').join(', ')}, which nothing reads. '
        'Known keys: ${known.map((k) => '`$k`').join(', ')}. An unknown key '
        'is refused rather than ignored because the common one is a typo, '
        'and a typo that silently kept the default is a plant serving on an '
        'ephemeral port with a green log');
  }

  static int _port(
      Map<String, dynamic> json, String source, Map<String, String> env) {
    final override = env[RelayEnv.port];
    if (override != null) {
      final parsed = int.tryParse(override.trim());
      if (parsed == null || parsed < 0 || parsed > 65535) {
        throw ArgumentError('relay config: ${RelayEnv.port}="$override" is '
            'not a TCP port in 0-65535');
      }
      return parsed;
    }
    if (!json.containsKey('port')) {
      throw ArgumentError('relay config: relay.port is missing in $source. It '
          'is required rather than defaulted because ServerConfig\'s default '
          'is 0 — an ephemeral port, which is right for a test\'s free-port '
          'draw and wrong for a plant whose panels are configured with a '
          'fixed address: they come up unable to find the backend, on a boot '
          'that reported no error. Say `"port": 0` deliberately if that is '
          'what is meant');
    }
    final value = json['port'];
    if (value is! int) {
      throw ArgumentError('relay config: relay.port is "$value" '
          '(${value.runtimeType}) in $source, not a number');
    }
    if (value < 0 || value > 65535) {
      throw ArgumentError(
          'relay config: relay.port is $value in $source, outside 0-65535');
    }
    return value;
  }

  static InternetAddress? _address(
      Map<String, dynamic> json, String source, Map<String, String> env) {
    final override = env[RelayEnv.address];
    if (override != null) {
      return _parseAddress(override, RelayEnv.address);
    }
    if (!json.containsKey('address')) return null;
    final value = json['address'];
    if (value is! String) {
      throw ArgumentError('relay config: relay.address is "$value" '
          '(${value.runtimeType}) in $source, not a string');
    }
    return _parseAddress(value, 'relay.address in $source');
  }

  static InternetAddress _parseAddress(String value, String what) {
    try {
      return InternetAddress(value);
    } on ArgumentError {
      throw ArgumentError('relay config: $what is "$value", which is not a '
          'numeric IP address. A hostname would be resolved at bind time — '
          'possibly to an interface nobody meant to expose — so the literal '
          'address is what this takes (0.0.0.0 for every interface, 127.0.0.1 '
          'for loopback)');
    }
  }

  static TlsConfig? _tls(
      Map<String, dynamic> json, String source, Map<String, String> env) {
    Map<String, dynamic> fileTls = const <String, dynamic>{};
    if (json.containsKey('tls')) {
      final value = json['tls'];
      if (value is! Map) {
        throw ArgumentError('relay config: relay.tls is "$value" '
            '(${value.runtimeType}) in $source, not an object with '
            '`chain_path` and `key_path`');
      }
      fileTls = value.cast<String, dynamic>();
      _refuseUnknown(fileTls.keys, _knownTlsKeys, 'relay.tls', source);
    }

    final chain = env[RelayEnv.tlsChain] ??
        _optionalString(fileTls, 'chain_path', 'relay.tls', source);
    final key = env[RelayEnv.tlsKey] ??
        _optionalString(fileTls, 'key_path', 'relay.tls', source);
    final password = env[RelayEnv.tlsKeyPassword] ??
        _optionalString(fileTls, 'key_password', 'relay.tls', source);

    if (chain == null && key == null) {
      if (password != null) {
        throw ArgumentError('relay config: a TLS key password is configured '
            'with no certificate pair (relay.tls.chain_path and '
            'relay.tls.key_path, or ${RelayEnv.tlsChain} and '
            '${RelayEnv.tlsKey}) in $source');
      }
      return null;
    }
    if (chain == null) {
      throw ArgumentError('relay config: relay.tls.chain_path is missing in '
          '$source while a key is configured. TLS is all-or-nothing here: '
          'half a pair reaching bind time surfaces as a SecurityContext '
          'failure naming a file, and the failure mode nobody notices is a '
          'gateway that serves plaintext on the plant LAN. Set both, or '
          'neither, or ${RelayEnv.tlsChain}');
    }
    if (key == null) {
      throw ArgumentError('relay config: relay.tls.key_path is missing in '
          '$source while chain_path is set. TLS is all-or-nothing here: half '
          'a pair reaching bind time surfaces as a SecurityContext failure '
          'naming a file rather than as the configuration error it is. Set '
          'both, or neither, or ${RelayEnv.tlsKey}');
    }
    return TlsConfig(
      chainPath: chain,
      keyPath: key,
      keyPassword: password,
    );
  }

  static RelayCredentials _credentials(
      Map<String, dynamic> json, String source, Map<String, String> env) {
    final envToken = env[RelayEnv.tokenFile];

    if (!json.containsKey('credentials')) {
      throw ArgumentError('relay config: relay.credentials is missing in '
          '$source. It is required rather than defaulted because the default '
          'would be an unauthenticated WebSocket on the plant LAN arriving '
          'through a line somebody left out. Say it: '
          '{"source": "none"}, {"source": "token_file", "token_file": "…"} '
          'or {"source": "validator"}');
    }
    final raw = json['credentials'];
    if (raw is! Map) {
      throw ArgumentError('relay config: relay.credentials is "$raw" '
          '(${raw.runtimeType}) in $source, not an object with a `source`');
    }
    final credentials = raw.cast<String, dynamic>();
    _refuseUnknown(
        credentials.keys, _knownCredentialKeys, 'relay.credentials', source);

    final sourceName = credentials['source'];
    if (sourceName is! String) {
      throw ArgumentError('relay config: relay.credentials.source is missing '
          'or not a string in $source. One of: `none`, `token_file`, '
          '`validator`');
    }
    final fileToken =
        _optionalString(credentials, 'token_file', 'relay.credentials', source);

    switch (sourceName) {
      case 'none':
        if (fileToken != null) {
          throw ArgumentError('relay config: relay.credentials.source is '
              '`none` but a `token_file` is named in $source. Set the source '
              'to `token_file` to use it, or remove it');
        }
        // An env-supplied token file upgrades a `none` deployment; that is one
        // source, stated in one place, not two.
        return envToken == null
            ? const RelayNoCredentialCheck()
            : RelayTokenFileCredentials(envToken);

      case 'token_file':
        final path = envToken ?? fileToken;
        if (path == null || path.trim().isEmpty) {
          throw ArgumentError('relay config: relay.credentials.token_file is '
              'missing or empty in $source while the source is `token_file`. '
              'An empty path reaches dart:io as the process working '
              'directory, so the backend fails to start with a message about '
              'a directory nobody configured');
        }
        return RelayTokenFileCredentials(path);

      case 'validator':
        if (fileToken != null) {
          throw ArgumentError('relay config: relay.credentials in $source '
              'names both `source: validator` and a `token_file`. Two sources '
              'of truth for the credential check is a configuration nobody '
              'can reason about, and the one that wins would be an '
              'implementation detail — RelayServer refuses the same pair at '
              'construction (relay_server.dart:155), and refusing it here '
              'means the refusal happens while somebody is reading the config '
              'rather than at boot on a plant machine. Drop one');
        }
        if (envToken != null) {
          throw ArgumentError('relay config: ${RelayEnv.tokenFile} is set to '
              '"$envToken" while relay.credentials.source in $source is '
              '`validator`. Two sources of truth for the credential check is '
              'a configuration nobody can reason about, and the one that wins '
              'would be an implementation detail (relay_server.dart:155). '
              'Unset ${RelayEnv.tokenFile}, or change the source to '
              '`token_file`');
        }
        return const RelayValidatorCredentials();

      default:
        throw ArgumentError('relay config: relay.credentials.source is '
            '"$sourceName" in $source, which nothing implements. One of: '
            '`none`, `token_file`, `validator`');
    }
  }

  static List<String>? _allowedOrigins(
      Map<String, dynamic> json, String source) {
    if (!json.containsKey('allowed_origins')) return null;
    final value = json['allowed_origins'];
    if (value is! List) {
      throw ArgumentError('relay config: relay.allowed_origins is "$value" '
          '(${value.runtimeType}) in $source, not a list of origin strings');
    }
    final origins = <String>[];
    for (final entry in value) {
      if (entry is! String) {
        throw ArgumentError('relay config: relay.allowed_origins in $source '
            'contains "$entry" (${entry.runtimeType}), which is not a string');
      }
      origins.add(entry);
    }
    return origins;
  }

  static String? _optionalString(
      Map<String, dynamic> json, String key, String path, String source) {
    if (!json.containsKey(key)) return null;
    final value = json[key];
    if (value == null) return null;
    if (value is! String) {
      throw ArgumentError('relay config: $path.$key is "$value" '
          '(${value.runtimeType}) in $source, not a string');
    }
    return value;
  }
}
