/// Certificates for a test, minted at test time and never committed.
///
/// CONTEXT is explicit about the rule and 06-RESEARCH §B.3 explains the cost
/// that makes it painless: an RSA-2048 keypair is 158–201 ms on a Mac and
/// closer to a second on the Windows runner, while a certificate signed from
/// an existing pair is ~15–34 ms. So the keypairs are generated once for the
/// process and every certificate a case wants is a fresh mint. The near-expiry
/// leaf SEC-04 needs is a `notAfter` argument (§G.3), not a second keygen.
///
/// **Why the cache is a lazy top-level and not a `setUpAll` in this file.**
/// A support file that registers `setUpAll` registers it for every suite that
/// imports it, including the ones that never touch a certificate — so importing
/// this file to reach one path helper would cost half a second of RSA in a
/// suite that mints nothing. The pairs are generated on first use instead.
///
/// **Everything here hands back PEM strings and filesystem paths — never a
/// `SecurityContext`, never bytes.** That is the same paths-not-bytes
/// discipline `TlsConfig` carries in 06-03, and a fixture that obeyed a
/// different one would let a "no key material outside mounted files" sweep
/// pass while the tests proved something else.
///
/// Without this file, every TLS plan in the phase invents its own certificate,
/// and the first one that gets the IP SAN wrong (trap 12) hides the bug behind
/// a hostname dial.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_server/src/tls/mint.dart';

/// A certificate authority a case can sign leaves under.
///
/// Carries its PEM pair — what production code is handed — plus the DN and the
/// keypair it was minted from, which is what [mintLeaf] needs to sign and what
/// keeps a second mint from costing a second RSA keygen.
final class TestCa {
  const TestCa({
    required this.certPem,
    required this.keyPem,
    required this.dn,
    required this.keys,
  });

  /// The root certificate, as a client pins it.
  final String certPem;

  /// The root's private key, as `SecurityContext.usePrivateKey` reads it.
  final String keyPem;

  /// The issuer name every leaf under this root carries.
  final Map<String, String> dn;

  /// The keypair the root was minted from; leaves are signed with it.
  final RelayKeyPair keys;
}

/// The paths [writeCertFixture] wrote, and the directory holding them.
typedef CertFixture = ({
  String directory,
  String chainPath,
  String keyPath,
  String? rootPath,
});

({RelayKeyPair ca, RelayKeyPair leaf})? _pairs;

/// The one CA keypair and the one leaf keypair this process uses.
///
/// Generated on first call and reused for the life of the isolate. Two calls
/// hand back the identical records — the case in `tls_mint_test.dart` asserts
/// that, because a cache that silently regenerated would only show up as a CI
/// lane getting slower.
({RelayKeyPair ca, RelayKeyPair leaf}) certKeyPairs() =>
    _pairs ??= (ca: generateKeyPair(), leaf: generateKeyPair());

/// The leaf private key every [mintLeaf] result is paired with.
String leafKeyPem() => privateKeyToPem(certKeyPairs().leaf.privateKey);

/// A ten-year private root, the way the plant's is provisioned.
TestCa mintCa({String commonName = 'Relay Test CA'}) {
  final keys = certKeyPairs().ca;
  final dn = {'CN': commonName, 'O': 'Centroid'};
  final now = DateTime.now().toUtc();
  return TestCa(
    certPem: mintCertificate(
      signingKey: keys.privateKey,
      issuer: dn,
      subject: dn,
      subjectPublicKey: keys.publicKey,
      notBefore: now.subtract(const Duration(days: 1)),
      notAfter: now.add(const Duration(days: 3650)),
      ca: true,
    ),
    keyPem: privateKeyToPem(keys.privateKey),
    dn: dn,
    keys: keys,
  );
}

/// A root that is *not* the one a pinned client trusts, for the rejection arms
/// in 06-03 and 06-05.
///
/// It reuses the leaf keypair as its signing key rather than generating a
/// third: what makes a CA foreign is that the client does not carry its root,
/// and this one has both a different key and a different name from [mintCa]'s.
/// A third keygen would buy nothing but another 200 ms in every suite that
/// imports this file.
TestCa mintForeignCa({String commonName = 'Someone Else Entirely'}) {
  final keys = certKeyPairs().leaf;
  final dn = {'CN': commonName, 'O': 'Not Centroid'};
  final now = DateTime.now().toUtc();
  return TestCa(
    certPem: mintCertificate(
      signingKey: keys.privateKey,
      issuer: dn,
      subject: dn,
      subjectPublicKey: keys.publicKey,
      notBefore: now.subtract(const Duration(days: 1)),
      notAfter: now.add(const Duration(days: 3650)),
      ca: true,
    ),
    keyPem: privateKeyToPem(keys.privateKey),
    dn: dn,
    keys: keys,
  );
}

/// A gateway leaf signed by [ca].
///
/// [sans] defaults to the pair every fixture in this phase actually dials.
/// The IP is not decoration: 06-07's fault proxy is reached at
/// `127.0.0.1:<proxy port>`, and a hostname-only leaf would fail that
/// handshake instead of exercising the fault the case was written for.
///
/// [notAfter] is how a case asks for a near-expiry certificate — 06-09's
/// 17-day leaf and 06-03's already-expired one are this call with a different
/// argument, not a different code path.
String mintLeaf({
  required TestCa ca,
  List<String> sans = const ['localhost', '127.0.0.1'],
  DateTime? notBefore,
  DateTime? notAfter,
  String commonName = 'relay-gateway',
}) {
  final now = DateTime.now().toUtc();
  return mintCertificate(
    signingKey: ca.keys.privateKey,
    issuer: ca.dn,
    subject: {'CN': commonName, 'O': 'Centroid'},
    subjectPublicKey: certKeyPairs().leaf.publicKey,
    sans: sans,
    notBefore: notBefore ?? now.subtract(const Duration(days: 1)),
    notAfter: notAfter ?? now.add(const Duration(days: 365)),
  );
}

/// Writes a chain, its key and optionally the root into a fresh temp
/// directory, and hands back the paths.
///
/// The recursive delete is registered with `addTearDown` **at acquisition**,
/// the same discipline `ws_harness.dart:239-244` uses for sockets: a case that
/// fails an assertion before its own cleanup line still releases what it took,
/// and private key material does not survive a red run on the machine.
///
/// The directory is under `Directory.systemTemp` and never inside the
/// checkout, so a crashed run cannot leave a key somewhere `git add` would
/// find it.
CertFixture writeCertFixture({
  required String chainPem,
  required String keyPem,
  String? rootPem,
}) {
  final dir = Directory.systemTemp.createTempSync('relay-certs-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  final chainPath = '${dir.path}${Platform.pathSeparator}chain.pem';
  final keyPath = '${dir.path}${Platform.pathSeparator}chain-key.pem';
  File(chainPath).writeAsStringSync(chainPem);
  File(keyPath).writeAsStringSync(keyPem);

  String? rootPath;
  if (rootPem != null) {
    rootPath = '${dir.path}${Platform.pathSeparator}root.pem';
    File(rootPath).writeAsStringSync(rootPem);
  }

  return (
    directory: dir.path,
    chainPath: chainPath,
    keyPath: keyPath,
    rootPath: rootPath,
  );
}
