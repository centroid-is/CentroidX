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
/// **Secrets are paths; the trust anchor is material.** The station
/// credential stays a file the integrator mounted — a token in a preferences
/// row is a token in every database backup and every support bundle. The CA
/// root, though, is *public* material (it is what the gateway hands anyone
/// who asks its trust endpoint), and carrying it as [GatewayConfig.caPem] is
/// what lets the whole gateway configuration be one typed URL: Save fetches
/// the root from the gateway, the operator approves its fingerprint — the
/// same "Server identity … Approve / Reject" ceremony noVNC runs on this
/// plant's rigs — and the approved bytes are pinned here. The legacy
/// [GatewayConfig.caCertPath] keeps dialling and migrates to material on the
/// next save ([GatewayConfig.migrateLegacyTrust]).
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
    this.caPem,
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

  /// The plant's CA root as PEM text — what the operator approved by
  /// fingerprint, or what a fleet tool seeded. Preferred over [caCertPath]
  /// at dial time: material is the thing a human vouched for, a path is a
  /// file that may have rotted since.
  ///
  /// Public material, deliberately in the row. The pin itself stays
  /// `SecurityContext(withTrustedRoots: false)` inside `RemoteStateMan`, so a
  /// gateway whose CA changes is a hard handshake refusal — never a prompt.
  final String? caPem;

  /// The legacy provisioning shape: the plant's CA root as a file on this
  /// station. Still dials; [migrateLegacyTrust] turns it into [caPem] on the
  /// next save. Refused for `ws` alongside [caPem], mirroring
  /// `ClientConfig.checkDialable`.
  final String? caCertPath;

  /// A file holding this station's credential, one line. Null when the gateway
  /// runs no token file, which is the shipped default on the rig.
  final String? tokenPath;

  bool get isGateway => mode == TransportMode.gateway;

  GatewayConfig copyWith({
    TransportMode? mode,
    String? url,
    String? caPem,
    String? caCertPath,
    String? tokenPath,
    bool clearCaPem = false,
    bool clearCaCertPath = false,
    bool clearTokenPath = false,
  }) =>
      GatewayConfig(
        mode: mode ?? this.mode,
        url: url ?? this.url,
        caPem: clearCaPem ? null : (caPem ?? this.caPem),
        caCertPath: clearCaCertPath ? null : (caCertPath ?? this.caCertPath),
        tokenPath: clearTokenPath ? null : (tokenPath ?? this.tokenPath),
      );

  Map<String, Object?> toJson() => {
        'mode': mode.wireName,
        'url': url,
        if (caPem != null) 'ca_pem': caPem,
        if (caCertPath != null) 'ca_cert_path': caCertPath,
        if (tokenPath != null) 'token_path': tokenPath,
      };

  factory GatewayConfig.fromJson(Map<String, Object?> json) => GatewayConfig(
        mode: TransportMode.parse(json['mode']),
        url: json['url'] is String ? json['url'] as String : '',
        caPem: _material(json['ca_pem']),
        caCertPath: _nonEmpty(json['ca_cert_path']),
        tokenPath: _nonEmpty(json['token_path']),
      );

  static String? _nonEmpty(Object? raw) =>
      raw is String && raw.trim().isNotEmpty ? raw.trim() : null;

  /// Like [_nonEmpty] but **never trims**: the pinned material must stay
  /// byte-identical to what the operator approved, or the fingerprint shown
  /// later for "what does this panel trust" stops matching the file the
  /// gateway serves.
  static String? _material(Object? raw) =>
      raw is String && raw.trim().isNotEmpty ? raw : null;

  /// Whether this station already holds a trust anchor for a `wss` dial —
  /// approved material, or the legacy provisioned file.
  bool get hasPinnedTrust => caPem != null || caCertPath != null;

  /// Whether Save's next act is the fetch-and-approve ceremony: a `wss` dial
  /// with nothing pinned yet and no other refusal standing.
  ///
  /// The gate on [validationError] is not decoration — a URL that does not
  /// parse has no host to fetch from, and one complaint at a time is this
  /// class's standing rule about a string somebody is halfway through typing.
  bool get needsTrustAcquisition =>
      isGateway &&
      validationError == null &&
      uri.scheme == 'wss' &&
      !hasPinnedTrust;

  /// Why the operator cannot *save* this, or null when they can.
  ///
  /// Returned as a sentence rather than thrown, because the caller is a text
  /// field an operator is halfway through typing into.
  ///
  /// **Missing trust is deliberately not refused here — that used to be this
  /// getter's fourth arm, and moving it is the one-URL flow.** Save is now
  /// the step that acquires trust (fetch the gateway's identity, show the
  /// fingerprint, pin on approval), so an edit-time refusal for the thing
  /// Save is about to provide would disable the very button that provides it
  /// — the deadlock the old PEM-path field hid behind "how do I obtain pem
  /// path". The boot side did not weaken: [undialable] still carries the
  /// arm, and `stateManProvider` consults *that*, so a hand-edited trustless
  /// row still lands on `GatewayLinkKind.notBuilt` and the chip still says
  /// "Panel misconfigured".
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
    // The host has to look like a host. This arm arrived with
    // [normalizeGatewayAddress]: once the field supplies the missing scheme,
    // anything typed into it parses, and `wss://just some words` has the host
    // `just some words` — a URL by syntax and nothing by intent. Before the
    // normaliser that string was refused for having no scheme, and losing
    // that refusal would trade a sentence the operator can act on for a trust
    // fetch that fails later with a network error.
    //
    // Deliberately a shape test and not a resolution: the plant's own dial is
    // a container hostname that resolves nowhere from a developer's machine,
    // and a validator that refused it would be wrong about the one deployment
    // that matters. Letters, digits, dots and dashes are hostnames; brackets
    // and colons are IPv6 literals. `%` is excluded on purpose — `Uri`
    // percent-escapes an illegal host rather than rejecting it, so a typed
    // space arrives here as `just%20some%20words`, and admitting `%` for the
    // sake of an IPv6 zone id nobody dials would admit every typo with it.
    if (!RegExp(r'^[A-Za-z0-9._:\[\]-]+$').hasMatch(uri.host)) {
      return 'Not an address: "$trimmed" is not a host name or an IP address '
          'and a port. Type it like 10.50.10.11:9443';
    }
    if (uri.scheme == 'ws' && hasPinnedTrust) {
      return 'A CA root on a ws:// dial is never consulted — the config would '
          'read as encrypted while the traffic is not';
    }
    if (uri.scheme == 'ws' && tokenPath != null) {
      return 'A station credential on a ws:// dial crosses the plant LAN in '
          'the clear on every reconnect';
    }
    return null;
  }

  /// Why this configuration cannot be *dialled*, or null when it can.
  ///
  /// [validationError] plus the missing-trust arm. This is what the boot path
  /// (`stateManProvider`) consults: at boot there is no Save about to acquire
  /// anything, so a `wss` row with no pinned trust is exactly as undialable
  /// as it always was — and refusing it by name here is what keeps the
  /// refusal readable instead of the `CERTIFICATE_VERIFY_FAILED` a genuine
  /// impostor also produces.
  String? get undialable {
    final refusal = validationError;
    if (refusal != null) return refusal;
    if (isGateway && uri.scheme == 'wss' && !hasPinnedTrust) {
      return 'wss needs the plant CA pinned first: without it every handshake '
          'fails with the same error a real impostor produces. Save on the '
          'Server Config page fetches the gateway\'s identity for approval';
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
        'name, so check the certificate before you distrust the pinned CA.';
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
    // Material first: it is the thing a human vouched for by fingerprint,
    // where a path is a file that may have rotted since. A row carrying both
    // exists only mid-migration, and mid-migration the approved bytes win.
    final pem = caPem;
    return ClientConfig(
      token: token == null || token.isEmpty ? null : token,
      tls: pem != null
          ? ClientTlsConfig.pem(pem)
          : caCertPath == null
              ? null
              : ClientTlsConfig(rootCertPath: caCertPath!),
    );
  }

  /// The one save-time migration: a legacy [caCertPath] becomes pinned
  /// [caPem], same bytes, path dropped.
  ///
  /// **On save only, never on load** — a read path that rewrote preferences
  /// would turn every boot into a write, and a half-failed one into a
  /// corrupted row. No new trust decision is being made: the station already
  /// dialled under this file every day, so its contents move homes without a
  /// fingerprint ceremony.
  ///
  /// Fails *soft* in both directions, and the asymmetry is deliberate: an
  /// unreadable or certificate-free file keeps the path (a path that fails at
  /// boot at least fails with the notBuilt report naming the file, where a
  /// silently dropped pin fails as a fake impostor alarm), and material
  /// already pinned is returned untouched.
  ///
  /// Synchronous, and that is load-bearing twice over: the one caller is a
  /// Save handler inside a widget, where a real-IO future never completes
  /// under the test binding's fake async; and a one-file read at a button
  /// press is not the kind of latency an async signature buys anything for.
  GatewayConfig migrateLegacyTrust() {
    final path = caCertPath;
    if (caPem != null || path == null) return this;
    final String pem;
    try {
      pem = File(path).readAsStringSync();
    } on FileSystemException {
      return this;
    }
    if (!pem.contains('BEGIN CERTIFICATE')) return this;
    return copyWith(caPem: pem, clearCaCertPath: true);
  }

  @override
  bool operator ==(Object other) =>
      other is GatewayConfig &&
      other.mode == mode &&
      other.url == url &&
      other.caPem == caPem &&
      other.caCertPath == caCertPath &&
      other.tokenPath == tokenPath;

  @override
  int get hashCode => Object.hash(mode, url, caPem, caCertPath, tokenPath);

  /// Never the material body: public or not, a PEM in every log line trains
  /// people to stop reading configs.
  @override
  String toString() => 'GatewayConfig(${mode.wireName}, $url, '
      'ca=${caPem != null ? '<pinned material, ${caPem!.length} chars>' : caCertPath}, '
      'token=$tokenPath)';
}

/// Turns what an operator types into the URL the rest of the app dials.
///
/// The field asks for an address and a port, because that is what an
/// integrator has written down: `10.50.10.11:9443`, or `centroidx-backend:9443`
/// — a container hostname, which is what this plant's panels actually dial.
/// Neither is a URL, and neither can be repaired by `Uri.parse` after the
/// fact: a bare IPv4 literal parses as a *path*, while a hostname with a port
/// parses as the scheme `centroidx-backend` with the path `9443`, which a
/// naive check reads as "has a scheme" and then nothing can dial. So the test
/// here is textual and deliberately crude — no `://` means no scheme was
/// typed, and the secure one is supplied.
///
/// **`wss` and never `ws`.** Defaulting to the cleartext scheme would be this
/// function quietly choosing the plant's security for it. A bench gateway is
/// still reachable: type the `ws://` and it is kept exactly as typed, and
/// [GatewayConfig.validationError] still says what that costs.
///
/// Empty stays empty, so an operator halfway through clearing the field gets
/// "Enter the gateway address" rather than a refusal about `wss://`.
String normalizeGatewayAddress(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  if (trimmed.contains('://')) return trimmed;
  return 'wss://$trimmed';
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
