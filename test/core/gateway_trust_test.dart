@TestOn('vm')

/// The panel's half of the one-URL trust flow: derive where the gateway's
/// trust document lives from the only thing the operator typed, fetch it, and
/// compute the fingerprint **locally** — never off the endpoint's own claim.
///
/// The claim-vs-computed arm is the load-bearing one. The fetch is plaintext
/// by design (the served root is public; the trust step is the operator
/// approving the fingerprint), which means a middlebox can rewrite the
/// material — but it must not be able to *also vouch for it*: a fetcher that
/// trusted the served `sha256_fingerprint` field would show the operator
/// whatever the middlebox claimed about whatever the middlebox sent, and the
/// approval ceremony would be theatre. So the server here lies on purpose,
/// and the fetcher must not repeat the lie.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/gateway_trust.dart';

/// SHA-256("abc") — the FIPS 180-2 vector, same anchor the gateway side pins
/// in `trust_endpoint_test.dart`, which is what keeps the two sides' formats
/// agreeing by construction rather than by review.
const String _sha256OfAbc =
    'BA:78:16:BF:8F:01:CF:EA:41:41:40:DE:5D:AE:22:23:'
    'B0:03:61:A3:96:17:7A:9C:B4:10:FF:61:F2:00:15:AD';

final String _abcPem = '-----BEGIN CERTIFICATE-----\n'
    '${base64.encode('abc'.codeUnits)}\n'
    '-----END CERTIFICATE-----\n';

/// A plaintext trust endpoint answering with [body], on an ephemeral port.
///
/// Returns the wss URI whose port+1 derivation lands on this listener, so the
/// fetcher's own arithmetic is what routes every case here.
Future<Uri> _endpoint(
    FutureOr<void> Function(HttpRequest request) answer) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    await answer(request);
    await request.response.close();
  });
  return Uri.parse('wss://127.0.0.1:${server.port - 1}');
}

void main() {
  group('the fingerprint, computed here, matches the gateway side', () {
    test('the FIPS "abc" vector, colon-hex, uppercase', () {
      expect(caFingerprintSha256(_abcPem), _sha256OfAbc,
          reason: 'this string is compared — by a human — against the one '
              'the gateway printed; a format that drifts from the server '
              'side\'s makes every comparison silently impossible');
    });

    test('material with no certificate block is refused', () {
      expect(() => caFingerprintSha256('not a pem'),
          throwsA(isA<GatewayTrustException>()),
          reason: 'a fingerprint of nothing still renders as plausible hex, '
              'and an operator would approve it');
    });
  });

  group('the trust URI is derived, never typed', () {
    test('wss://host:9443 derives http://host:9444/relay-trust', () {
      expect(deriveTrustUri(Uri.parse('wss://10.50.10.11:9443')),
          Uri.parse('http://10.50.10.11:9444/relay-trust'));
    });

    test('a ws dial has no trust to fetch and is refused', () {
      expect(() => deriveTrustUri(Uri.parse('ws://10.50.10.11:9443')),
          throwsA(isA<GatewayTrustException>()),
          reason: 'a plaintext dial consults no root; fetching one for it '
              'would build the exact config validationError refuses');
    });
  });

  group('fetching', () {
    test('returns the material with a locally computed fingerprint, and '
        'ignores what the endpoint claimed', () async {
      final wss = await _endpoint((request) {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'ca_pem': _abcPem,
            // The lie. A middlebox that rewrites the material writes
            // whatever it likes here; the ceremony only means something if
            // this field is never read.
            'sha256_fingerprint': 'AA:AA:AA:AA:AA:AA:AA:AA',
          }));
      });

      final trust = await fetchGatewayTrust(wss);
      expect(trust.caPem, _abcPem);
      expect(trust.sha256Fingerprint, _sha256OfAbc,
          reason: 'the fingerprint shown for approval must be computed from '
              'the received DER on this panel — an endpoint (or a middlebox) '
              'must not be able to vouch for its own material');
    });

    test('a refusal names the derived URL, not a stack', () async {
      final wss = await _endpoint((request) {
        request.response.statusCode = 500;
      });

      await expectLater(
        fetchGatewayTrust(wss),
        throwsA(isA<GatewayTrustException>().having(
            (e) => e.message, 'message', contains('/relay-trust'))),
        reason: 'the operator reading this refusal typed one URL; the '
            'sentence has to say where the panel actually went on their '
            'behalf',
      );
    });

    test('a gateway with no trust endpoint reads as absent, not as a crash',
        () async {
      // Nothing listens on port+1 of this wss URI: bind and immediately
      // close, so the port is known-dead rather than merely unlikely.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close(force: true);

      await expectLater(
        fetchGatewayTrust(Uri.parse('wss://127.0.0.1:${port - 1}')),
        throwsA(isA<GatewayTrustException>().having((e) => e.message,
            'message', contains('did not answer'))),
        reason: 'an older gateway serves no trust document; the panel must '
            'say that in operator words — with the remedy being to update '
            'the gateway — rather than leak a SocketException',
      );
    });

    test('a document that is not the trust document is refused', () async {
      final wss = await _endpoint((request) {
        request.response
          ..statusCode = 200
          ..write('<html>a captive portal, say</html>');
      });

      await expectLater(
        fetchGatewayTrust(wss),
        throwsA(isA<GatewayTrustException>()),
        reason: 'anything on the path between panel and gateway can answer '
            'port 9444; only the document shape says whether the gateway '
            'did',
      );
    });

    test('served material with no certificate in it is refused before any '
        'fingerprint exists', () async {
      final wss = await _endpoint((request) {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'ca_pem': 'garbage', 'sha256_fingerprint': ''}));
      });

      await expectLater(
        fetchGatewayTrust(wss),
        throwsA(isA<GatewayTrustException>()),
        reason: 'the approval dialog must never render a fingerprint of '
            'nothing — an operator who approves it has pinned garbage and '
            'the next boot fails with a message about trust',
      );
    });
  });
}
