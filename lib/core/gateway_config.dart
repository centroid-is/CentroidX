/// Which pipe this station's values come down, and where the far end is.
///
/// **Per-station, never synced.** A gateway URL has exactly the property that
/// made `DatabaseConfig` unsafe to sync: two stations on the same plant reach
/// the same service at different addresses, and one synced row silently
/// re-points the other. So this lives in device-local preferences
/// (`localPreferencesProvider`) beside the startup URL and the MCP toggles,
/// and it is deliberately absent from the `StoredServerConfig` envelope that
/// import/export moves between machines.
///
/// **Paths, never secrets.** Both the CA root and the station credential are
/// named by a file the integrator mounted, not carried as bytes. That is the
/// discipline `ClientTlsConfig` already states for the root ("bytes on a
/// config object end up in a preferences row, a log line or a crash dump") and
/// the credential deserves it more, not less: a token in a preferences row is
/// a token in every database backup and every support bundle. The operator
/// types two paths; the operating system's permissions still apply to what is
/// behind them.
library;

import 'dart:convert';
import 'dart:io';

import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart';

import 'gateway_link_status.dart' show isIpLiteralHost;

/// Where a station gets its values from.
enum TransportMode {
  /// This station opens its own OPC UA sessions, Modbus sockets and Postgres
  /// pool. What the plant runs today.
  direct,

  /// This station holds one WebSocket to the relay gateway for its **values**:
  /// no OPC UA session, no Modbus socket, no collector.
  ///
  /// It holds **no direct database connection**. It once did — the rig
  /// measured a panel in gateway mode with the connection open
  /// (13-RIG-E2E-EVIDENCE FIND-C) because `lib/providers/database.dart` had no
  /// transport branch, and `preferencesProvider` is keepAlive and watched it
  /// unconditionally, so the pool came up at boot with no screen asking for it.
  /// Phase 17 moved access, preferences and the audit trail onto the relay, and
  /// `databaseProvider` now branches on the transport before it reads the
  /// configuration row, spawns a pool or arms the retry probe. The backend owns
  /// the database; this station reaches it only through the socket.
  gateway;

  /// The name persisted in preferences. Parsing is by this string, so renaming
  /// an enum constant does not silently re-point every station to `direct`.
  String get wireName => name;

  static TransportMode parse(Object? raw) => switch (raw) {
        'gateway' => TransportMode.gateway,
        _ => TransportMode.direct,
      };
}

/// The station's transport choice and, when it is [TransportMode.gateway], the
/// three things a dial needs.
final class GatewayConfig {
  const GatewayConfig({
    this.mode = TransportMode.direct,
    this.url = '',
    this.caCertPath,
    this.tokenPath,
  });

  /// A station that has never been configured runs exactly as it does today.
  /// Direct mode is the default in every direction: an absent preferences row,
  /// a corrupt one, and an unparseable mode string all land here.
  static const GatewayConfig defaults = GatewayConfig();

  /// The device-local preferences key. Namespaced so a future second relay
  /// setting is a field in this object rather than a second row nobody diffs.
  static const String prefsKey = 'gateway_transport';

  final TransportMode mode;

  /// `wss://host:port` — or `ws://` for a bench gateway, which the validator
  /// permits and the UI marks.
  final String url;

  /// The plant's private CA root, as provisioned to this station. Required for
  /// `wss`, refused for `ws` — both mirroring `ClientConfig.checkDialable`, so
  /// the operator reads the refusal in the settings page instead of watching a
  /// panel fail to construct at boot.
  final String? caCertPath;

  /// A file holding this station's credential, one line. Null when the gateway
  /// runs no token file, which is the shipped default on the rig.
  final String? tokenPath;

  bool get isGateway => mode == TransportMode.gateway;

  GatewayConfig copyWith({
    TransportMode? mode,
    String? url,
    String? caCertPath,
    String? tokenPath,
    bool clearCaCertPath = false,
    bool clearTokenPath = false,
  }) =>
      GatewayConfig(
        mode: mode ?? this.mode,
        url: url ?? this.url,
        caCertPath: clearCaCertPath ? null : (caCertPath ?? this.caCertPath),
        tokenPath: clearTokenPath ? null : (tokenPath ?? this.tokenPath),
      );

  Map<String, Object?> toJson() => {
        'mode': mode.wireName,
        'url': url,
        if (caCertPath != null) 'ca_cert_path': caCertPath,
        if (tokenPath != null) 'token_path': tokenPath,
      };

  factory GatewayConfig.fromJson(Map<String, Object?> json) => GatewayConfig(
        mode: TransportMode.parse(json['mode']),
        url: json['url'] is String ? json['url'] as String : '',
        caCertPath: _nonEmpty(json['ca_cert_path']),
        tokenPath: _nonEmpty(json['token_path']),
      );

  static String? _nonEmpty(Object? raw) =>
      raw is String && raw.trim().isNotEmpty ? raw.trim() : null;

  /// Why this configuration cannot be dialled, or null when it can.
  ///
  /// Returned as a sentence rather than thrown, because the caller is a text
  /// field an operator is halfway through typing into. `RemoteStateMan` throws
  /// on the same three combinations at construction; this exists so the
  /// operator sees them while the keyboard is still in their hands rather than
  /// as a dark screen at the next restart.
  String? get validationError {
    if (!isGateway) return null;
    final trimmed = url.trim();
    if (trimmed.isEmpty) return 'Enter the gateway address, e.g. wss://10.50.10.11:9443';
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return 'Not a URL: expected wss://host:port';
    }
    if (uri.scheme != 'wss' && uri.scheme != 'ws') {
      return 'Scheme must be wss (or ws for a bench gateway), not ${uri.scheme}';
    }
    if (uri.scheme == 'wss' && caCertPath == null) {
      return 'wss needs the plant CA root: without it every handshake fails '
          'with the same error a real impostor produces';
    }
    if (uri.scheme == 'ws' && caCertPath != null) {
      return 'A CA root on a ws:// dial is never consulted — the config would '
          'read as encrypted while the traffic is not';
    }
    if (uri.scheme == 'ws' && tokenPath != null) {
      return 'A station credential on a ws:// dial crosses the plant LAN in '
          'the clear on every reconnect';
    }
    return null;
  }

  /// A warning about this configuration that is **not** a reason to refuse it.
  ///
  /// Fires when a `wss` address names a host rather than an address. The
  /// gateway's certificate has to carry a subject-alternative name for exactly
  /// that host, and when it does not, TLS reports the mismatch as a *trust*
  /// failure — which sends the operator to the CA file, the wrong end of the
  /// wire. The rig measured the trap: its probe leaf is `CN=10.50.10.11` with
  /// `SAN: IP Address:10.50.10.11` and no DNS name at all, so the panel had to
  /// be pointed at `wss://10.50.10.11:9444` for hostname verification to pass
  /// (13-RIG-E2E-EVIDENCE FIND-B). Said here, it costs the operator a glance;
  /// discovered at the next restart, it costs an afternoon.
  ///
  /// **It must never enter the Save button's enable condition.** That switch is
  /// `_hasUnsavedChanges && refusal == null` where `refusal` is
  /// [validationError] alone (`lib/pages/server_config.dart:1147-1179`), and
  /// this getter stays out of it. A plant that provisions DNS SANs is
  /// perfectly legitimate — it is only *this* deployment's certificate that
  /// cannot serve a name — and a configuration the operator is not allowed to
  /// save is worse than one they save and then correct.
  ///
  /// Null whenever [validationError] is not: one complaint at a time about a
  /// string somebody is halfway through typing.
  String? get advisory {
    if (!isGateway) return null;
    if (validationError != null) return null;
    if (uri.scheme != 'wss') return null;
    // The one is-this-a-name-or-an-address test in the app. It lives in
    // `gateway_link_status.dart` because the other caller — that file's SAN
    // hint, which must stay quiet on an IP-literal dial — is in a file that may
    // not import `dart:io`, so the direction of the collapse is forced.
    //
    // **This comment used to claim the reverse, and was wrong about it.** It
    // said the SAN hint "calls this getter rather than growing a second
    // spelling". It did not: it had its own `_isIpLiteral`, did not import this
    // file, and the two disagreed on `1.2.3.+4`, `0x1.2.3.4` and `a:b`. What
    // that cost is not theoretical — this advisory is the *proactive* half of
    // rig FIND-B and the SAN hint is the *reactive* half, so a host the two
    // spellings disagreed about got the warning while the operator was typing
    // and then no hint at all when the handshake failed, or the other way
    // round. One spelling is what makes them agree by construction.
    //
    // `InternetAddress.tryParse` was here and is measurably better on
    // degenerate input; it is not available to the other caller, so
    // `gateway_config_test.dart`'s differential arm keeps it as the control and
    // the one remaining divergence is a written-down host rather than a
    // surprise. A `host.contains('.')` shortcut, for the record, reads
    // 10.50.10.11 as a name and an IPv6 literal as an address — both backwards.
    if (isIpLiteralHost(uri.host)) return null;
    return 'The gateway certificate must carry a subject-alternative name for '
        'exactly "${uri.host}". A certificate issued for an IP address instead '
        'fails the handshake with a message about trust rather than about the '
        'name, so check the certificate before you touch the CA root path.';
  }

  /// The dial target, once [validationError] is null.
  Uri get uri => Uri.parse(url.trim());

  /// Turns this into the client package's own config, reading the credential
  /// off disk.
  ///
  /// **The token is read here and nowhere else** — once per client, at the
  /// moment the connection is built, and it is never written back to
  /// preferences. A missing or unreadable token file is a thrown
  /// [FileSystemException] rather than a silent null: a panel that quietly
  /// drops its credential connects as an unknown station and is refused by the
  /// gateway with a message about authentication, which sends the engineer to
  /// the wrong end of the wire.
  Future<ClientConfig> toClientConfig() async {
    final path = tokenPath;
    final token = path == null ? null : (await File(path).readAsString()).trim();
    return ClientConfig(
      token: token == null || token.isEmpty ? null : token,
      tls: caCertPath == null
          ? null
          : ClientTlsConfig(rootCertPath: caCertPath!),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GatewayConfig &&
      other.mode == mode &&
      other.url == url &&
      other.caCertPath == caCertPath &&
      other.tokenPath == tokenPath;

  @override
  int get hashCode => Object.hash(mode, url, caCertPath, tokenPath);

  @override
  String toString() => 'GatewayConfig(${mode.wireName}, $url, '
      'ca=$caCertPath, token=$tokenPath)';
}

/// Reads the station's transport choice, falling back to direct mode.
///
/// A corrupt row reads as [GatewayConfig.defaults] rather than throwing. The
/// alternative is a panel that will not boot because somebody hand-edited a
/// preferences row, and direct mode is the configuration the plant already
/// runs.
Future<GatewayConfig> readGatewayConfig(PreferencesApi prefs) async {
  final raw = await prefs.getString(GatewayConfig.prefsKey);
  if (raw == null) return GatewayConfig.defaults;
  try {
    return GatewayConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  } catch (_) {
    return GatewayConfig.defaults;
  }
}

/// Writes the station's transport choice to the device-local store.
Future<void> writeGatewayConfig(
    PreferencesApi prefs, GatewayConfig config) async {
  await prefs.setString(GatewayConfig.prefsKey, jsonEncode(config.toJson()));
}
