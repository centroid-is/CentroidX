/// The panel's half of the one-URL trust flow.
///
/// The operator types `wss://10.50.10.11:9443` and nothing else. Everything
/// here exists to make that sentence true: [deriveTrustUri] turns the typed
/// URL into the gateway's trust endpoint (`http://…:9444/relay-trust` — the
/// port offset is a convention shared with `tfc_relay_server`'s
/// `tls/trust.dart`, not a knob), [fetchGatewayTrust] fetches the plant's CA
/// root from it, and [caFingerprintSha256] computes what the approval dialog
/// shows — **locally, from the received DER, never off the endpoint's own
/// claim**. The fetch is plaintext by design: the served root is public
/// material, and a TLS fetch from the very gateway the panel does not yet
/// trust would be circular. What makes the flow trustworthy is the ceremony
/// around it — the operator compares the fingerprint against the one printed
/// where the gateway's certificates were minted, and only an approval pins
/// anything. A middlebox on the path can rewrite the material; it must not be
/// able to vouch for it, which is why the served `sha256_fingerprint` field is
/// decoration for humans with `curl` and is never read here.
///
/// **This is not `badCertificateCallback` wearing a coat.** Nothing in this
/// file touches a TLS handshake, accepts a certificate, or opens the socket
/// the values will travel on. It moves public bytes and shows a human a hash;
/// the pin itself stays `SecurityContext(withTrustedRoots: false)` inside
/// `RemoteStateMan`, and a later change of CA is a hard handshake refusal
/// there — never a re-prompt here.
///
/// Errors leave as [GatewayTrustException] with a sentence an operator can
/// act on, because the caller is a settings page, not a log file.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart' show CryptoUtils;

/// The path and port-offset convention, mirrored from the gateway's
/// `tls/trust.dart`. Constants on both sides so the one thing the operator
/// types is enough to find the document.
const String kRelayTrustPath = '/relay-trust';

/// `wss` port + this = the trust endpoint's port.
const int kRelayTrustPortOffset = 1;

/// How long the whole fetch may take before the settings page says so.
///
/// A commissioning operator is standing at the panel watching this; ten
/// seconds is already long enough to reach for the network tester, and the
/// unreachable-address pathology this bounds is 75 s on macOS (06-RESEARCH
/// §C.4).
const Duration kTrustFetchBudget = Duration(seconds: 10);

/// A trust-flow failure, in words the Server Config page can show whole.
final class GatewayTrustException implements Exception {
  GatewayTrustException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What a successful fetch hands the approval dialog.
final class FetchedGatewayTrust {
  FetchedGatewayTrust({required this.caPem, required this.sha256Fingerprint});

  /// The plant's CA root, byte-identical to what the gateway served — this is
  /// what gets pinned on approval, so any normalisation here would make the
  /// pinned material differ from the file whose fingerprint the operator
  /// compared.
  final String caPem;

  /// SHA-256 over the DER of [caPem], computed on this panel. Colon-separated
  /// uppercase hex — the form `openssl x509 -fingerprint -sha256` prints, so
  /// the comparison the dialog asks for is character-by-character.
  final String sha256Fingerprint;

  @override
  String toString() => 'FetchedGatewayTrust($sha256Fingerprint)';
}

/// Where [wssUri]'s gateway serves its trust document.
///
/// Refuses anything but `wss`: a plaintext dial consults no root, and
/// fetching one for it would build the exact configuration
/// `GatewayConfig.validationError` refuses.
Uri deriveTrustUri(Uri wssUri) {
  if (wssUri.scheme != 'wss') {
    throw GatewayTrustException(
        'only a wss gateway has an identity to fetch — ${wssUri.scheme}:// '
        'dials are plaintext and consult no certificate at all');
  }
  return Uri(
    scheme: 'http',
    host: wssUri.host,
    port: wssUri.port + kRelayTrustPortOffset,
    path: kRelayTrustPath,
  );
}

/// SHA-256 of the first certificate in [pem]: colon-separated uppercase hex
/// over the DER bytes — the same computation, character for character, as the
/// gateway side's `caFingerprintSha256`, pinned on both sides by the FIPS
/// "abc" vector so the two cannot drift apart unnoticed.
String caFingerprintSha256(String pem) {
  final block = RegExp(
    r'-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----',
  ).firstMatch(pem);
  if (block == null) {
    throw GatewayTrustException(
        'the material carries no certificate: a fingerprint of nothing would '
        'still render as plausible hex, and approving it would pin garbage');
  }
  final der = base64.decode(block.group(1)!.replaceAll(RegExp(r'\s'), ''));
  final digest = CryptoUtils.getHashPlain(Uint8List.fromList(der),
      algorithmName: 'SHA-256');
  return digest
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');
}

/// Fetches the gateway's CA root for the approval dialog.
///
/// [client] is a seam for tests; production passes nothing and gets a plain
/// `HttpClient` — plain deliberately, see the library doc.
Future<FetchedGatewayTrust> fetchGatewayTrust(
  Uri wssUri, {
  HttpClient? client,
  Duration budget = kTrustFetchBudget,
}) async {
  final trustUri = deriveTrustUri(wssUri);
  final http = client ?? HttpClient();
  http.connectionTimeout = budget;
  try {
    final String body;
    final int status;
    try {
      final request = await http.getUrl(trustUri).timeout(budget);
      final response = await request.close().timeout(budget);
      status = response.statusCode;
      body = await response.transform(utf8.decoder).join().timeout(budget);
    } on GatewayTrustException {
      rethrow;
    } on TimeoutException {
      throw GatewayTrustException(
          'the gateway did not answer at $trustUri within '
          '${budget.inSeconds} s. Check that the address is right and the '
          'gateway is running, then save again.');
    } catch (error) {
      throw GatewayTrustException(
          'the gateway did not answer at $trustUri ($error). If the address '
          'is right and the gateway is running, it may be an older build '
          'with no trust endpoint — update the gateway, or provision the '
          'plant CA to this station another way.');
    }

    if (status != 200) {
      throw GatewayTrustException(
          'the gateway answered $status at $trustUri instead of its trust '
          'document. Check that the address names the relay gateway and not '
          'something else on that machine.');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw GatewayTrustException(
          'what answered at $trustUri is not the gateway\'s trust document. '
          'Anything on the network can answer that port; only the relay '
          'gateway serves this document, so check the address.');
    }
    final caPem = decoded is Map<String, dynamic> ? decoded['ca_pem'] : null;
    if (caPem is! String || caPem.trim().isEmpty) {
      throw GatewayTrustException(
          'the document at $trustUri carries no certificate material, so '
          'there is nothing to show for approval. Check the gateway\'s '
          'trust configuration.');
    }

    // Computed here, from what actually arrived. The served
    // `sha256_fingerprint` field is deliberately never read — see the
    // library doc, and the arm in `gateway_trust_test.dart` where the
    // endpoint lies about it.
    return FetchedGatewayTrust(
      caPem: caPem,
      sha256Fingerprint: caFingerprintSha256(caPem),
    );
  } finally {
    if (client == null) http.close(force: true);
  }
}
