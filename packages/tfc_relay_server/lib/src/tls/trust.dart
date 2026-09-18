/// The gateway's trust endpoint: one public document, so a panel can be
/// configured by typing one URL.
///
/// The operator's whole configuration is `wss://host:9443`. The panel derives
/// `http://host:9444/relay-trust` from it, fetches this document, computes the
/// SHA-256 fingerprint of the received root **locally**, and shows it to the
/// operator for approval — the same "Server identity … Approve / Reject"
/// ceremony noVNC already runs on this plant's rigs. Only an approval pins
/// anything, and what is pinned is the CA, so the yearly leaf re-issue changes
/// nothing on any panel.
///
/// **Plaintext, and deliberately.** The served root is public material — it is
/// what the gateway hands anyone who completes a handshake anyway — and
/// serving it over TLS from the very gateway the fetcher does not yet trust
/// would be circular. The trust step is the fingerprint approval, never the
/// transport of the fetch. The one discipline that follows: this listener
/// serves exactly one document at exactly one path, because anything else that
/// grows here grows on an unauthenticated plaintext port.
///
/// **Port + 1 is a convention, not a knob.** A configurable trust port would
/// be a second thing to type, which is the failure the flow exists to remove.
///
/// [caPath] is a path, like every other server-side certificate reference —
/// the paths-never-bytes ruling is untouched on this side of the wire, where
/// the neighbouring fields are private keys.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';

/// Where the CA root this gateway serves for pinning is mounted.
final class TrustConfig {
  TrustConfig({required this.caPath}) {
    if (caPath.trim().isEmpty) {
      throw ArgumentError('caPath is empty: a trust endpoint with no root to '
          'serve would answer the first commissioning fetch with a 500 and '
          'nothing in it naming the file that was never configured');
    }
  }

  /// The PEM holding the plant's CA root — the file `relay_certs` wrote
  /// beside the chain, and the same bytes a pinned panel verifies under.
  final String caPath;

  @override
  String toString() => 'TrustConfig(caPath: $caPath)';
}

/// The path the document is served at, and the offset the client derives the
/// port from. Constants rather than configuration on both sides, so the one
/// thing the operator types is enough to find it.
const String relayTrustPath = '/relay-trust';

/// `wss` port + this = the trust endpoint's port.
const int relayTrustPortOffset = 1;

/// What `GET /relay-trust` answers: the root, and the human-facing claim.
///
/// The fingerprint field exists for a person with `curl` comparing against a
/// panel's dialog. A client must never read it — the whole point of the
/// ceremony is that the panel computes its own from [caPem], so a middlebox
/// that rewrites the material cannot also vouch for it.
final class TrustDocument {
  TrustDocument({required this.caPem})
      : sha256Fingerprint = caFingerprintSha256(caPem);

  /// The root certificate, byte-identical to the provisioned file, so the
  /// served fingerprint matches what `openssl x509 -fingerprint -sha256`
  /// prints for it.
  final String caPem;

  /// SHA-256 over the DER, colon-separated uppercase hex.
  final String sha256Fingerprint;

  String toJsonString() => jsonEncode({
        'ca_pem': caPem,
        'sha256_fingerprint': sha256Fingerprint,
      });
}

/// SHA-256 of the first certificate in [pem], in the form `openssl` prints:
/// colon-separated uppercase hex over the DER bytes.
///
/// The DER and nothing else. Hashing the PEM text would make the value depend
/// on line wrapping and trailing newlines — two files with identical
/// certificates and different editors would show different fingerprints, and
/// the operator comparing them would refuse a genuine gateway.
String caFingerprintSha256(String pem) {
  final block = RegExp(
    r'-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----',
  ).firstMatch(pem);
  if (block == null) {
    throw ArgumentError('no BEGIN CERTIFICATE block in the material: a '
        'fingerprint of nothing would still render as plausible hex, and an '
        'operator would approve it');
  }
  final der = base64.decode(block.group(1)!.replaceAll(RegExp(r'\s'), ''));
  final digest = SHA256Digest().process(Uint8List.fromList(der));
  return digest
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');
}
