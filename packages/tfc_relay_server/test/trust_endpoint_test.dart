@TestOn('vm')

/// The gateway's trust endpoint: its own CA root, served in the clear, so a
/// panel can be configured by typing one URL.
///
/// **Why plaintext is correct here and nowhere else.** The document served is
/// the plant's CA *root certificate* — public material, the thing the gateway
/// hands to anyone who completes a TLS handshake anyway. Serving it over TLS
/// from the same gateway would be circular: the fetching panel does not trust
/// the gateway yet, that is the whole reason it is fetching. The trust step is
/// not the transport; it is the operator approving the SHA-256 fingerprint the
/// *panel computes locally* from what arrived. The endpoint's own
/// `sha256_fingerprint` field is decoration for a human with `curl`; the
/// client-side fetcher recomputes and never reads it, and
/// `test/core/gateway_trust_test.dart` in the app holds it to that.
///
/// **Port + 1 is a convention, not a knob.** The operator types
/// `wss://host:9443` and nothing else, so the client must be able to *derive*
/// where the trust document lives. A configurable trust port would be a second
/// thing to type, which is the failure this whole flow exists to remove.
///
/// **The CA is read at start, loudly.** Same posture as a misspelled
/// `chainPath`: a gateway that cannot open the file it was told to serve must
/// refuse to start, not 500 on the first fetch a commissioning afternoon
/// depends on.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';

import 'support/certs.dart';
import 'support/permissive_resolver.dart';

/// SHA-256("abc"), the FIPS 180-2 test vector — what makes the fingerprint
/// case a check against an outside authority rather than against itself.
const String _sha256OfAbc =
    'BA:78:16:BF:8F:01:CF:EA:41:41:40:DE:5D:AE:22:23:'
    'B0:03:61:A3:96:17:7A:9C:B4:10:FF:61:F2:00:15:AD';

/// A PEM whose DER body is exactly the bytes `abc`.
///
/// Not a certificate at all — the fingerprint function hashes the decoded
/// body and must not care, because hashing anything *else* (the PEM text, a
/// re-encoding, the claimed fingerprint) would produce a value that never
/// matches what `openssl x509 -fingerprint -sha256` prints for the same file,
/// and the person comparing the two is the operator this flow exists for.
final String _abcPem = '-----BEGIN CERTIFICATE-----\n'
    '${base64.encode('abc'.codeUnits)}\n'
    '-----END CERTIFICATE-----\n';

Future<({RelayServer server, String rootPem, String rootPath})> _gateway(
    {required TestCa ca}) async {
  final fixture = writeCertFixture(
    chainPem: mintLeaf(ca: ca),
    keyPem: leafKeyPem(),
    rootPem: ca.certPem,
  );
  // A CONSECUTIVE PAIR, not port 0. The trust listener binds `wss port + 1`
  // by design — the client has only the URL the operator typed to derive it
  // from — so an ephemeral main port makes the neighbour a lottery: the OS
  // hands out `p`, something unrelated already owns `p + 1`, and the bind dies
  // with "Address already in use" in a run that has nothing to do with trust.
  // That is not flakiness to be retried away; it is what asking for a port you
  // did not reserve means. So reserve both, then release them and hand the
  // base to the gateway. The race that remains (something grabs one in the
  // microseconds between release and bind) is the same one every
  // reserve-then-bind faces and is vastly narrower than gambling on p + 1.
  final base = await _freeConsecutivePair();
  final server = RelayServer(
    resolver: const PermissiveSeriesResolver(),
    api: FakeStateMan(),
    config: ServerConfig(
      tick: ServerConfig.minTick,
      port: base,
      tls: TlsConfig(chainPath: fixture.chainPath, keyPath: fixture.keyPath),
      trust: TrustConfig(caPath: fixture.rootPath!),
    ),
    onError: (_, __, ___) {},
  );
  addTearDown(server.close);
  await server.start();
  return (server: server, rootPem: ca.certPem, rootPath: fixture.rootPath!);
}

/// A port `p` where both `p` and `p + 1` are free, for the `+1` convention.
///
/// Binds `p` ephemerally, then explicitly binds `p + 1` to prove the
/// neighbour is actually available rather than assuming it, and releases
/// both. Retries because the second bind legitimately fails when the OS
/// happens to hand out a port whose neighbour is taken.
Future<int> _freeConsecutivePair() async {
  for (var attempt = 0; attempt < 40; attempt++) {
    final first = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    ServerSocket? second;
    try {
      second = await ServerSocket.bind(
          InternetAddress.loopbackIPv4, first.port + 1);
    } on SocketException {
      await first.close();
      continue;
    }
    final port = first.port;
    await first.close();
    await second.close();
    return port;
  }
  throw StateError('no consecutive free port pair after 40 attempts');
}

/// One plain-HTTP GET, returning status and body.
Future<({int status, String body})> _get(Uri uri) async {
  final client = HttpClient();
  addTearDown(() => client.close(force: true));
  final request = await client.getUrl(uri);
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  return (status: response.statusCode, body: body);
}

void main() {
  group('the fingerprint is computed over the DER, colon-hex, uppercase', () {
    test('a known vector: the body "abc" hashes to the FIPS value', () {
      expect(caFingerprintSha256(_abcPem), _sha256OfAbc,
          reason: 'this is the string an operator compares against what the '
              'gateway printed; any deviation — hashing the PEM text, '
              'lowercase, no colons — makes the comparison silently '
              'impossible and every approval a shrug');
    });

    test('material with no certificate block is refused by name', () {
      expect(
        () => caFingerprintSha256('not a pem at all'),
        throwsA(isA<ArgumentError>()
            .having((e) => '$e', 'message', contains('BEGIN CERTIFICATE'))),
        reason: 'a fingerprint of nothing would still render as a plausible '
            'hex string, and an operator would approve it',
      );
    });
  });

  group('the configuration refusals', () {
    test('an empty caPath is refused at construction', () {
      expect(
        () => TrustConfig(caPath: ''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a trust endpoint on a plaintext gateway is refused', () {
      expect(
        () => ServerConfig(trust: TrustConfig(caPath: '/tmp/ca.pem')),
        throwsA(isA<ArgumentError>()
            .having((e) => '$e', 'message', contains('trust'))),
        reason: 'a plaintext gateway has no certificate for the served root '
            'to vouch for — the endpoint would offer panels an anchor that '
            'anchors nothing, and the panel would then refuse ws:// dials '
            'for carrying it',
      );
    });

    test('a caPath naming a missing file refuses to start, loudly', () async {
      final ca = mintCa();
      final fixture = writeCertFixture(
        chainPem: mintLeaf(ca: ca),
        keyPem: leafKeyPem(),
      );
      final server = RelayServer(
        resolver: const PermissiveSeriesResolver(),
        api: FakeStateMan(),
        config: ServerConfig(
          tick: ServerConfig.minTick,
          tls: TlsConfig(
              chainPath: fixture.chainPath, keyPath: fixture.keyPath),
          trust: TrustConfig(
              caPath: '${fixture.directory}/no-such-root.pem'),
        ),
        onError: (_, __, ___) {},
      );
      addTearDown(server.close);
      await expectLater(server.start(), throwsA(isA<FileSystemException>()),
          reason: 'the same posture as a misspelled chainPath: fail at '
              'start, where the message names the file, not at the first '
              'fetch of a commissioning afternoon');
    });
  });

  group('the endpoint itself', () {
    test('serves the CA and a fingerprint that matches it, on port + 1',
        () async {
      final gateway = await _gateway(ca: mintCa());
      final port = gateway.server.port;

      final answer =
          await _get(Uri.parse('http://127.0.0.1:${port + 1}/relay-trust'));
      expect(answer.status, 200);

      final doc = jsonDecode(answer.body) as Map<String, dynamic>;
      expect(doc['ca_pem'], gateway.rootPem,
          reason: 'the served material must be byte-identical to the root '
              'the gateway\'s own leaf verifies under — a re-encoding would '
              'still pin, but its fingerprint would no longer match what '
              'openssl prints for the provisioned file');
      expect(doc['sha256_fingerprint'],
          caFingerprintSha256(gateway.rootPem),
          reason: 'the human-facing claim and the material must agree; a '
              'client never reads this field, but the operator comparing '
              'a curl against the panel dialog does');
    });

    test('anything but GET /relay-trust is 404, and serves no material',
        () async {
      final gateway = await _gateway(ca: mintCa());
      final port = gateway.server.port;

      final answer =
          await _get(Uri.parse('http://127.0.0.1:${port + 1}/anything-else'));
      expect(answer.status, 404);
      expect(answer.body, isNot(contains('BEGIN CERTIFICATE')),
          reason: 'one path, deliberately: this listener exists to serve one '
              'public document, and anything that grows here grows on an '
              'unauthenticated plaintext port');
    });

    test('a gateway with no TrustConfig binds nothing beside itself',
        () async {
      final ca = mintCa();
      final fixture = writeCertFixture(
        chainPem: mintLeaf(ca: ca),
        keyPem: leafKeyPem(),
      );
      final server = RelayServer(
        resolver: const PermissiveSeriesResolver(),
        api: FakeStateMan(),
        config: ServerConfig(
          tick: ServerConfig.minTick,
          tls: TlsConfig(
              chainPath: fixture.chainPath, keyPath: fixture.keyPath),
        ),
        onError: (_, __, ___) {},
      );
      addTearDown(server.close);
      await server.start();

      await expectLater(
        _get(Uri.parse('http://127.0.0.1:${server.port + 1}/relay-trust')),
        throwsA(isA<SocketException>()),
        reason: 'every existing deployment and fixture constructs without '
            'trust:, and none of them may grow a listener they did not ask '
            'for — port + 1 belongs to whoever bound it first',
      );
    });

    test('close() takes the trust listener down with the gateway', () async {
      final gateway = await _gateway(ca: mintCa());
      final port = gateway.server.port;
      await gateway.server.close();

      await expectLater(
        _get(Uri.parse('http://127.0.0.1:${port + 1}/relay-trust')),
        throwsA(isA<SocketException>()),
        reason: 'a listener that outlives close() holds the port against '
            'the restarted gateway and serves a document whose gateway is '
            'gone',
      );
    });
  });
}
